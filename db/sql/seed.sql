-- Seven days of synthetic history so the dashboard and the AI agent have
-- something to work with on first boot. qa_review is deliberately slow:
-- that is the bottleneck the demo is meant to surface.
SET ROLE ops_writer;

DO $$
DECLARE
  mean_minutes CONSTANT jsonb :=
    '{"received": 6, "validated": 12, "qa_review": 38, "packed": 14, "shipped": 180}';
  stage_order  CONSTANT text[] :=
    ARRAY['received', 'validated', 'qa_review', 'packed', 'shipped', 'delivered'];
  c   int;
  i   int;
  ts  timestamptz;
BEGIN
  PERFORM setseed(0.42);  -- same data on every fresh install
  FOR c IN 1..700 LOOP
    ts := now() - random() * interval '7 days';
    FOR i IN 1..array_length(stage_order, 1) LOOP
      EXIT WHEN ts > now();
      INSERT INTO process_events (case_id, stage, event_ts, source)
      VALUES (format('ORD-%s', lpad(c::text, 5, '0')), stage_order[i], ts, 'seed');
      EXIT WHEN i = array_length(stage_order, 1);
      -- exponential wait with the stage's mean, so a few cases take far longer
      ts := ts + make_interval(
        mins => greatest(1, round(-ln(1 - random()) * (mean_minutes ->> stage_order[i])::numeric))::int);
    END LOOP;
  END LOOP;
END $$;

RESET ROLE;
