-- Ops warehouse: raw process events + modelled views.
-- Objects are owned by ops_writer; ops_analyst only gets SELECT.
SET ROLE ops_writer;

-- Process definition: every case moves through these stages in order.
CREATE TABLE stages (
  stage        text PRIMARY KEY,
  seq          int  NOT NULL UNIQUE,
  sla_minutes  int            -- NULL = terminal stage, no SLA
);

INSERT INTO stages (stage, seq, sla_minutes) VALUES
  ('received',   1,  10),
  ('validated',  2,  20),
  ('qa_review',  3,  30),
  ('packed',     4,  25),
  ('shipped',    5, 240),
  ('delivered',  6, NULL);

-- Raw events, append-only. One row = "case X entered stage Y at time T".
CREATE TABLE process_events (
  id           bigserial PRIMARY KEY,
  case_id      text        NOT NULL,
  stage        text        NOT NULL REFERENCES stages(stage),
  event_ts     timestamptz NOT NULL,
  source       text        NOT NULL DEFAULT 'api',
  payload      jsonb       NOT NULL DEFAULT '{}',
  ingested_at  timestamptz NOT NULL DEFAULT now(),
  UNIQUE (case_id, stage)              -- idempotent ingest: replays are ignored
);
CREATE INDEX process_events_case_ts ON process_events (case_id, event_ts);
CREATE INDEX process_events_ts      ON process_events (event_ts);

-- One alert per (case, stage) breach, so the alert workflow never spams.
CREATE TABLE alerts (
  id                bigserial PRIMARY KEY,
  created_at        timestamptz NOT NULL DEFAULT now(),
  case_id           text NOT NULL,
  stage             text NOT NULL,
  minutes_in_stage  int  NOT NULL,
  sla_minutes       int  NOT NULL,
  severity          text NOT NULL,
  UNIQUE (case_id, stage)
);

-- Written by the n8n Error Workflow for any failed production execution.
CREATE TABLE workflow_errors (
  id            bigserial PRIMARY KEY,
  created_at    timestamptz NOT NULL DEFAULT now(),
  workflow      text,
  node          text,
  message       text,
  execution_id  text,
  execution_url text
);

-- ---------------------------------------------------------------- views

-- Time spent in each stage, per case. Open stages are measured up to now().
CREATE VIEW v_case_stage_durations AS
SELECT
  e.case_id,
  e.stage,
  s.seq,
  s.sla_minutes,
  e.event_ts                                               AS entered_at,
  lead(e.event_ts) OVER w                                  AS exited_at,
  lead(e.event_ts) OVER w IS NULL                          AS is_open,
  round(extract(epoch FROM coalesce(lead(e.event_ts) OVER w, now()) - e.event_ts) / 60.0, 1)
                                                           AS minutes_in_stage
FROM process_events e
JOIN stages s USING (stage)
WINDOW w AS (PARTITION BY e.case_id ORDER BY s.seq);

-- Cases still in flight, with their current stage and SLA status.
CREATE VIEW v_open_cases AS
SELECT
  case_id,
  stage            AS current_stage,
  entered_at,
  minutes_in_stage,
  sla_minutes,
  minutes_in_stage > sla_minutes AS breached
FROM v_case_stage_durations
WHERE is_open AND sla_minutes IS NOT NULL;

-- The bottleneck report: where do cases wait, and how often do we miss SLA?
CREATE VIEW v_stage_bottlenecks AS
SELECT
  s.seq,
  s.stage,
  s.sla_minutes,
  count(*) FILTER (WHERE NOT d.is_open)                                          AS completed_7d,
  round(avg(d.minutes_in_stage) FILTER (WHERE NOT d.is_open), 1)                 AS avg_minutes,
  round((percentile_cont(0.5)  WITHIN GROUP (ORDER BY d.minutes_in_stage)
         FILTER (WHERE NOT d.is_open))::numeric, 1)                              AS p50_minutes,
  round((percentile_cont(0.95) WITHIN GROUP (ORDER BY d.minutes_in_stage)
         FILTER (WHERE NOT d.is_open))::numeric, 1)                              AS p95_minutes,
  round(100.0 * count(*) FILTER (WHERE NOT d.is_open AND d.minutes_in_stage > s.sla_minutes)
        / nullif(count(*) FILTER (WHERE NOT d.is_open), 0), 1)                   AS sla_breach_pct,
  count(*) FILTER (WHERE d.is_open)                                              AS open_now,
  count(*) FILTER (WHERE d.is_open AND d.minutes_in_stage > s.sla_minutes)       AS open_breached
FROM stages s
LEFT JOIN v_case_stage_durations d
  ON d.stage = s.stage AND d.entered_at > now() - interval '7 days'
WHERE s.sla_minutes IS NOT NULL
GROUP BY s.seq, s.stage, s.sla_minutes
ORDER BY s.seq;

-- Hourly flow: cases started vs. cases delivered.
CREATE VIEW v_throughput_hourly AS
SELECT
  date_trunc('hour', event_ts)                       AS hour,
  count(*) FILTER (WHERE stage = 'received')         AS cases_started,
  count(*) FILTER (WHERE stage = 'delivered')        AS cases_delivered
FROM process_events
GROUP BY 1;

-- End-to-end lead time for delivered cases.
CREATE VIEW v_case_lead_time AS
SELECT
  case_id,
  min(event_ts)                                                      AS started_at,
  max(event_ts)                                                      AS delivered_at,
  round(extract(epoch FROM max(event_ts) - min(event_ts)) / 3600.0, 2) AS lead_time_hours
FROM process_events
GROUP BY case_id
HAVING bool_or(stage = 'delivered');

RESET ROLE;

GRANT CONNECT ON DATABASE ops TO ops_analyst;
GRANT USAGE ON SCHEMA public TO ops_analyst;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO ops_analyst;
-- Belt and braces: the analyst role can never write, even by accident.
ALTER ROLE ops_analyst SET default_transaction_read_only = on;
ALTER ROLE ops_analyst SET statement_timeout = '10s';
