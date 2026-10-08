-- =====================================================================
-- Stride & Soul — operational schema (PostgreSQL 17)
-- Migrated from the Calzados Djohn Supabase scripts 00-10.
-- Business rules live here, not in the prompt: CHECK constraints,
-- a sequence for receipt numbers and a trigger that guards stock.
-- Safe to re-run (IF NOT EXISTS / OR REPLACE).
-- =====================================================================

-- Settings that differ by market; read by the functions in 03_functions.sql.
CREATE TABLE IF NOT EXISTS settings (
  key         text PRIMARY KEY,
  value       text NOT NULL,
  description text
);

-- Catalog: one row per product variant. Stock is per variant, not per size.
CREATE TABLE IF NOT EXISTS catalog (
  product_id  bigint PRIMARY KEY,
  model       text          NOT NULL,
  brand       text          NOT NULL,
  type        text          NOT NULL CHECK (type IN ('sneakers', 'shoes', 'ankle boots', 'boots', 'sandals')),
  subculture  text          NOT NULL CHECK (subculture IN ('punk', 'hardcore', 'straight edge', 'emo', 'goth', 'metal')),
  size_range  text          NOT NULL,              -- EU sizes, e.g. '35-44'
  color       text          NOT NULL,
  price       numeric(8,2)  NOT NULL CHECK (price >= 0),   -- final price, tax included
  stock       integer       NOT NULL DEFAULT 0 CHECK (stock >= 0),
  created_at  timestamptz   NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_catalog_subculture ON catalog (subculture);
CREATE INDEX IF NOT EXISTS idx_catalog_type       ON catalog (type);
CREATE INDEX IF NOT EXISTS idx_catalog_brand      ON catalog (brand);

-- Policies: ready-to-send answers by topic. Topics starting with internal_
-- describe agent behaviour and are never quoted to customers.
CREATE TABLE IF NOT EXISTS shipping_policy (
  topic   text PRIMARY KEY,
  content text NOT NULL
);
CREATE TABLE IF NOT EXISTS return_policy (
  topic   text PRIMARY KEY,
  content text NOT NULL
);

-- Receipt numbers: SS-000001, SS-000002... never reused.
CREATE SEQUENCE IF NOT EXISTS seq_ticket START 1;

-- Sales: positive quantity = sale, negative quantity = refund (credit note).
CREATE TABLE IF NOT EXISTS sales (
  sale_id          bigserial PRIMARY KEY,
  ticket_seq       bigint        NOT NULL UNIQUE DEFAULT nextval('seq_ticket'),
  ticket_no        text          GENERATED ALWAYS AS ('SS-' || lpad(ticket_seq::text, 6, '0')) STORED UNIQUE,
  user_hash        text          NOT NULL,          -- salted hash of the Telegram user id
  customer_name    text,
  contact          text,                            -- e-mail for the receipt
  product_id       bigint        REFERENCES catalog (product_id),
  quantity         integer       NOT NULL CHECK (quantity <> 0),
  items            text          NOT NULL,
  base_amount      numeric(10,2) NOT NULL,          -- without tax
  tax_amount       numeric(10,2) NOT NULL,
  total_amount     numeric(10,2) NOT NULL,          -- products, tax included
  shipping_fee     numeric(10,2) NOT NULL DEFAULT 0 CHECK (shipping_fee >= 0),
  status           text          NOT NULL DEFAULT 'validated'
                   CHECK (status IN ('validated', 'in_progress', 'delivered', 'refunded', 'exchanged')),
  sale_ref_ticket  text          REFERENCES sales (ticket_no),   -- original sale of a refund or exchange
  comment          text,
  created_at       timestamptz   NOT NULL DEFAULT now(),
  -- A sale has positive amounts, a credit note negative ones. Never mixed.
  CONSTRAINT chk_coherent_signs CHECK (
       (quantity > 0 AND base_amount >= 0 AND tax_amount >= 0 AND total_amount >= 0)
    OR (quantity < 0 AND base_amount <= 0 AND tax_amount <= 0 AND total_amount <= 0)),
  CONSTRAINT chk_total_adds_up CHECK (total_amount = base_amount + tax_amount)
);
CREATE INDEX IF NOT EXISTS idx_sales_user    ON sales (user_hash);
CREATE INDEX IF NOT EXISTS idx_sales_product ON sales (product_id);
CREATE INDEX IF NOT EXISTS idx_sales_ref     ON sales (sale_ref_ticket);

-- Stock engine: every positive sale takes pairs out of stock, or fails.
-- FOR UPDATE locks the catalog row, so two simultaneous sales of the last
-- pair are serialised and the second one sees stock 0 and is rejected.
CREATE OR REPLACE FUNCTION fn_take_stock() RETURNS trigger AS $$
DECLARE
  current_stock integer;
BEGIN
  IF NEW.quantity <= 0 OR NEW.product_id IS NULL THEN
    RETURN NEW;                       -- credit notes never touch stock
  END IF;

  SELECT stock INTO current_stock
  FROM catalog WHERE product_id = NEW.product_id
  FOR UPDATE;

  IF current_stock IS NULL THEN
    RAISE EXCEPTION 'NOT_FOUND: product % does not exist', NEW.product_id;
  END IF;
  IF current_stock < NEW.quantity THEN
    RAISE EXCEPTION 'OUT_OF_STOCK: product % has % left, % requested',
      NEW.product_id, current_stock, NEW.quantity;
  END IF;

  UPDATE catalog SET stock = stock - NEW.quantity WHERE product_id = NEW.product_id;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS trg_take_stock ON sales;
CREATE TRIGGER trg_take_stock
  BEFORE INSERT ON sales
  FOR EACH ROW EXECUTE FUNCTION fn_take_stock();

-- Returned pairs: they go to the recovery partner, never back to stock.
CREATE TABLE IF NOT EXISTS returns (
  return_id        bigserial PRIMARY KEY,
  original_ticket  text        NOT NULL REFERENCES sales (ticket_no),
  product_id       bigint      REFERENCES catalog (product_id),
  quantity         integer     NOT NULL CHECK (quantity > 0),
  type             text        NOT NULL CHECK (type IN ('refund', 'exchange')),
  destination      text        NOT NULL DEFAULT 'recovery_partner',
  reason           text,
  created_at       timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_returns_ticket ON returns (original_ticket);

-- Escalations to a person. Hard rule: no contact, no case.
CREATE TABLE IF NOT EXISTS support_cases (
  case_id          bigserial PRIMARY KEY,           -- shown to the customer as 0001
  user_hash        text        NOT NULL,
  customer_name    text,
  contact          text        NOT NULL CONSTRAINT chk_contact_required CHECK (length(trim(contact)) > 0),
  reason           text,
  escalation_type  text        NOT NULL CHECK (escalation_type IN
                   ('supervisor_request', 'legal_mention', 'incomplete_delivery',
                    'damaged_product', 'staff_complaint', 'other')),
  triage_area      text        NOT NULL DEFAULT 'other'
                   CHECK (triage_area IN ('product', 'store', 'staff', 'policies', 'other')),
  ticket_no        text        REFERENCES sales (ticket_no),
  attended         boolean     NOT NULL DEFAULT false,
  created_at       timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_cases_open ON support_cases (attended, created_at);

-- Process events: one row each time a conversation reaches a stage.
-- This is the stage-by-stage funnel used to find bottlenecks.
CREATE TABLE IF NOT EXISTS conversation_events (
  event_id      bigserial PRIMARY KEY,
  session_id    text        NOT NULL,
  user_hash     text        NOT NULL,
  stage         text        NOT NULL CHECK (stage IN
                ('start', 'catalog_query', 'data_validated', 'sale_registered',
                 'support_case', 'refund', 'exchange', 'contingency')),
  event_ts      timestamptz NOT NULL DEFAULT now(),
  execution_id  text,
  details       jsonb
);
CREATE INDEX IF NOT EXISTS idx_events_session ON conversation_events (session_id, event_ts);
CREATE INDEX IF NOT EXISTS idx_events_ts      ON conversation_events (event_ts);

-- Audit log: one row per turn. E-mails and phones are masked before insert;
-- full contact data only lives where it is needed (sales, support_cases).
CREATE TABLE IF NOT EXISTS audit_logs (
  log_id          bigserial PRIMARY KEY,
  user_hash       text        NOT NULL,
  input           text,
  output          text,
  validation      text,       -- ok | email_valid | email_invalid | no_validation
  slots_snapshot  jsonb,      -- e.g. {"name":"Kevin","email":"kev***@gmail.com"}
  summary         text,
  created_at      timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_audit_created ON audit_logs (created_at);

-- Execution metrics: one row per workflow execution (Playbook §2.1).
CREATE TABLE IF NOT EXISTS execution_metrics (
  metric_id      bigserial PRIMARY KEY,
  logged_at      timestamptz NOT NULL DEFAULT now(),
  execution_id   text        NOT NULL,
  workflow       text        NOT NULL,
  status         text        NOT NULL CHECK (status IN ('success', 'error', 'invalid_response')),
  started_at     timestamptz,
  finished_at    timestamptz,
  duration_s     numeric(10,3),
  node           text,       -- failing node, empty on success
  error          text,       -- sanitised message
  user_hash      text,       -- never a raw e-mail or phone
  registered_by  text        NOT NULL CHECK (registered_by IN ('MAIN_FLOW', 'ERROR_HANDLER'))
);
CREATE INDEX IF NOT EXISTS idx_metrics_logged ON execution_metrics (logged_at);

-- What the sales agent may offer: only variants in stock.
CREATE OR REPLACE VIEW v_catalog_available AS
SELECT product_id, model, brand, type, subculture, size_range, color, price, stock
FROM catalog
WHERE stock > 0;
