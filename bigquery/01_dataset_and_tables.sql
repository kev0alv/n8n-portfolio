-- =====================================================================
-- Stride & Soul — BigQuery analytics copy (sandbox, no billing)
-- Run 1 of 2 in BigQuery Studio. Safe to re-run.
--
-- BigQuery is NOT the system of record: Postgres is. Every night n8n
-- copies these tables from Postgres with load jobs (WRITE_TRUNCATE) and
-- re-runs 02_views.sql. The sandbox deletes tables after 60 days and does
-- not allow INSERT/UPDATE; a full nightly reload makes both irrelevant,
-- because anything that expires is recreated by the next load.
--
-- Not copied on purpose: audit_logs (conversation text stays in Postgres),
-- customer names and contact details (removed by the export query).
-- =====================================================================

CREATE SCHEMA IF NOT EXISTS stride_soul
OPTIONS (location = 'US', description = 'Stride & Soul analytics copy, reloaded nightly from Postgres');

CREATE TABLE IF NOT EXISTS stride_soul.catalog (
  product_id  INT64,
  model       STRING,
  brand       STRING,
  type        STRING,
  subculture  STRING,
  size_range  STRING,
  color       STRING,
  price       NUMERIC,
  stock       INT64,
  created_at  TIMESTAMP
);

CREATE TABLE IF NOT EXISTS stride_soul.sales (
  sale_id          INT64,
  ticket_no        STRING,
  user_hash        STRING,
  product_id       INT64,
  quantity         INT64,
  items            STRING,
  base_amount      NUMERIC,
  tax_amount       NUMERIC,
  total_amount     NUMERIC,
  shipping_fee     NUMERIC,
  status           STRING,
  sale_ref_ticket  STRING,
  created_at       TIMESTAMP
);

CREATE TABLE IF NOT EXISTS stride_soul.returns (
  return_id        INT64,
  original_ticket  STRING,
  product_id       INT64,
  quantity         INT64,
  type             STRING,
  destination      STRING,
  reason           STRING,
  created_at       TIMESTAMP
);

CREATE TABLE IF NOT EXISTS stride_soul.support_cases (
  case_id          INT64,
  user_hash        STRING,
  reason           STRING,
  escalation_type  STRING,
  triage_area      STRING,
  ticket_no        STRING,
  attended         BOOL,
  created_at       TIMESTAMP
);

CREATE TABLE IF NOT EXISTS stride_soul.conversation_events (
  event_id      INT64,
  session_id    STRING,
  user_hash     STRING,
  stage         STRING,
  event_ts      TIMESTAMP,
  execution_id  STRING
);

CREATE TABLE IF NOT EXISTS stride_soul.execution_metrics (
  metric_id      INT64,
  logged_at      TIMESTAMP,
  execution_id   STRING,
  workflow       STRING,
  status         STRING,
  started_at     TIMESTAMP,
  finished_at    TIMESTAMP,
  duration_s     FLOAT64,
  node           STRING,
  error          STRING,
  user_hash      STRING,
  registered_by  STRING
);
