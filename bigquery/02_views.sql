-- =====================================================================
-- Stride & Soul — analytics views (Looker Studio and the analyst agent
-- read these; they hold the business logic so nobody re-writes it).
-- Run 2 of 2, and re-run by the nightly n8n load. Safe to re-run.
-- =====================================================================

-- Stock position per product, with what sold in the last 30 days.
CREATE OR REPLACE VIEW stride_soul.v_stock_position AS
SELECT
  c.product_id, c.brand, c.model, c.color, c.subculture, c.type, c.price, c.stock,
  IFNULL(SUM(IF(s.quantity > 0 AND s.created_at >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 30 DAY),
                s.quantity, 0)), 0) AS pairs_sold_30d
FROM stride_soul.catalog c
LEFT JOIN stride_soul.sales s USING (product_id)
GROUP BY c.product_id, c.brand, c.model, c.color, c.subculture, c.type, c.price, c.stock;

-- Daily sales, refunds and exchanges.
CREATE OR REPLACE VIEW stride_soul.v_sales_daily AS
SELECT
  DATE(created_at, 'America/El_Salvador')                          AS day,
  COUNTIF(quantity > 0 AND sale_ref_ticket IS NULL)                AS sales,
  COUNTIF(quantity > 0 AND sale_ref_ticket IS NOT NULL)            AS exchanges,
  COUNTIF(quantity < 0)                                            AS refunds,
  SUM(IF(quantity > 0, quantity, 0))                               AS pairs_out,
  SUM(total_amount)                                                AS net_revenue,
  SUM(tax_amount)                                                  AS net_tax,
  SUM(IF(quantity > 0, total_amount, 0))
    / NULLIF(COUNTIF(quantity > 0), 0)                             AS avg_ticket
FROM stride_soul.sales
GROUP BY day;

-- Time spent between consecutive stages of each conversation.
CREATE OR REPLACE VIEW stride_soul.v_stage_durations AS
SELECT
  session_id,
  user_hash,
  stage,
  event_ts                                                         AS entered_at,
  LEAD(stage)    OVER w                                            AS next_stage,
  LEAD(event_ts) OVER w                                            AS exited_at,
  TIMESTAMP_DIFF(LEAD(event_ts) OVER w, event_ts, SECOND)          AS seconds_in_stage
FROM stride_soul.conversation_events
WINDOW w AS (PARTITION BY session_id ORDER BY event_ts);

-- Where conversations wait: the bottleneck report.
CREATE OR REPLACE VIEW stride_soul.v_stage_bottlenecks AS
SELECT
  stage,
  COUNT(*)                                                         AS transitions,
  ROUND(AVG(seconds_in_stage), 1)                                  AS avg_seconds,
  APPROX_QUANTILES(seconds_in_stage, 100)[OFFSET(50)]              AS p50_seconds,
  APPROX_QUANTILES(seconds_in_stage, 100)[OFFSET(95)]              AS p95_seconds
FROM stride_soul.v_stage_durations
WHERE seconds_in_stage IS NOT NULL
  AND entered_at >= TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 30 DAY)
GROUP BY stage;

-- Daily funnel: how many conversations reached each stage.
CREATE OR REPLACE VIEW stride_soul.v_funnel_daily AS
SELECT
  DATE(MIN(event_ts), 'America/El_Salvador')                       AS day,
  session_id,
  LOGICAL_OR(stage = 'start')                                      AS reached_start,
  LOGICAL_OR(stage = 'catalog_query')                              AS reached_catalog,
  LOGICAL_OR(stage = 'data_validated')                             AS reached_data_validated,
  LOGICAL_OR(stage = 'sale_registered')                            AS reached_sale,
  LOGICAL_OR(stage = 'support_case')                               AS escalated,
  LOGICAL_OR(stage = 'contingency')                                AS hit_contingency
FROM stride_soul.conversation_events
GROUP BY session_id;

-- Funnel conversion per day (one row per day, ready for a chart).
CREATE OR REPLACE VIEW stride_soul.v_funnel_conversion AS
SELECT
  day,
  COUNT(*)                                                         AS conversations,
  COUNTIF(reached_catalog)                                         AS catalog_queries,
  COUNTIF(reached_data_validated)                                  AS data_validated,
  COUNTIF(reached_sale)                                            AS sales,
  COUNTIF(escalated)                                               AS escalations,
  ROUND(100 * SAFE_DIVIDE(COUNTIF(reached_sale), COUNT(*)), 1)     AS conversion_pct,
  ROUND(100 * SAFE_DIVIDE(COUNT(*) - COUNTIF(escalated), COUNT(*)), 1) AS containment_pct
FROM stride_soul.v_funnel_daily
GROUP BY day;

-- Workflow health (Playbook §2.2): success, error and invalid-response rates.
CREATE OR REPLACE VIEW stride_soul.v_execution_kpis AS
SELECT
  DATE(logged_at, 'America/El_Salvador')                           AS day,
  workflow,
  COUNT(*)                                                         AS executions,
  COUNTIF(status = 'success')                                      AS successes,
  COUNTIF(status = 'error')                                        AS errors,
  COUNTIF(status = 'invalid_response')                             AS invalid_responses,
  ROUND(100 * SAFE_DIVIDE(COUNTIF(status = 'success'), COUNT(*)), 1) AS success_rate_pct,
  ROUND(100 * SAFE_DIVIDE(COUNTIF(status = 'error'), COUNT(*)), 1)   AS error_rate_pct,
  ROUND(AVG(duration_s), 2)                                        AS avg_duration_s,
  APPROX_QUANTILES(duration_s, 100)[OFFSET(50)]                    AS median_duration_s
FROM stride_soul.execution_metrics
GROUP BY day, workflow;

-- Open escalations, oldest first: the support team's queue.
CREATE OR REPLACE VIEW stride_soul.v_support_queue AS
SELECT
  case_id,
  IF(case_id > 9999, CAST(case_id AS STRING), LPAD(CAST(case_id AS STRING), 4, '0')) AS case_label,
  escalation_type,
  triage_area,
  ticket_no,
  reason,
  created_at,
  TIMESTAMP_DIFF(CURRENT_TIMESTAMP(), created_at, MINUTE)          AS minutes_waiting
FROM stride_soul.support_cases
WHERE NOT attended;
