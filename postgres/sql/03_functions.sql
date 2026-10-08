-- =====================================================================
-- Stride & Soul — transactional functions (what the agent's tools call)
-- Each function is one atomic operation: everything or nothing.
-- Called from n8n as:  SELECT * FROM register_sale($1, $2, $3, $4, $5);
--
-- Errors start with a code the agent can explain to the customer:
--   VALIDATION, NOT_FOUND, OUT_OF_STOCK, ALREADY_PROCESSED
-- Safe to re-run (CREATE OR REPLACE).
-- =====================================================================

CREATE OR REPLACE FUNCTION setting_numeric(p_key text) RETURNS numeric
LANGUAGE sql STABLE AS $$ SELECT value::numeric FROM settings WHERE key = p_key $$;


-- ---------------------------------------------------------------------
-- Register a sale of one product variant.
-- Stock is taken by trigger trg_take_stock (row lock, blocks overselling).
-- Tax is split out of the tax-included price; shipping is free from N pairs.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION register_sale(
  p_user_hash      text,
  p_customer_name  text,
  p_contact        text,
  p_product_id     bigint,
  p_quantity       integer
)
RETURNS TABLE (
  ticket_no      text,
  items          text,
  base_amount    numeric,
  tax_amount     numeric,
  total_amount   numeric,
  shipping_fee   numeric,
  amount_to_pay  numeric,
  stock_left     integer
)
LANGUAGE plpgsql AS $$
DECLARE
  v_product  catalog%ROWTYPE;
  v_total    numeric;
  v_base     numeric;
  v_ship     numeric;
  v_items    text;
  v_ticket   text;
BEGIN
  IF coalesce(trim(p_user_hash), '') = '' THEN
    RAISE EXCEPTION 'VALIDATION: user_hash is required';
  END IF;
  IF p_quantity IS NULL OR p_quantity <= 0 THEN
    RAISE EXCEPTION 'VALIDATION: quantity must be at least 1';
  END IF;
  -- The regex in n8n validates first; this is the deterministic last word.
  IF p_contact IS NULL OR trim(p_contact) !~ '^[^@\s,;]+@[^@\s,;]+\.[A-Za-z]{2,}$' THEN
    RAISE EXCEPTION 'VALIDATION: a valid e-mail is required to issue the receipt';
  END IF;

  SELECT * INTO v_product FROM catalog c WHERE c.product_id = p_product_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'NOT_FOUND: product % does not exist', p_product_id;
  END IF;

  v_total := v_product.price * p_quantity;
  v_base  := round(v_total / (1 + setting_numeric('tax_rate')), 2);
  v_ship  := CASE WHEN p_quantity >= setting_numeric('free_shipping_min_pairs') THEN 0
                  ELSE setting_numeric('shipping_fee') END;
  v_items := format('%s x %s %s (%s, %s)', p_quantity, v_product.brand, v_product.model,
                    v_product.color, v_product.size_range);

  INSERT INTO sales AS s (user_hash, customer_name, contact, product_id, quantity, items,
                          base_amount, tax_amount, total_amount, shipping_fee)
  VALUES (p_user_hash, coalesce(nullif(trim(p_customer_name), ''), 'Anonymous'), trim(p_contact),
          p_product_id, p_quantity, v_items, v_base, v_total - v_base, v_total, v_ship)
  RETURNING s.ticket_no INTO v_ticket;

  RETURN QUERY
  SELECT v_ticket, v_items, v_base, v_total - v_base, v_total, v_ship, v_total + v_ship,
         (SELECT c.stock FROM catalog c WHERE c.product_id = p_product_id);
END;
$$;


-- ---------------------------------------------------------------------
-- Full refund: credit note (negative sale) linked to the original
-- receipt, plus the returned pair. Stock is NOT restored.
-- The original sale row is locked, so two refunds of the same receipt
-- at the same time cannot both succeed.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION process_refund(
  p_original_ticket text,
  p_reason          text
)
RETURNS TABLE (
  credit_note_ticket text,
  original_ticket    text,
  items              text,
  refunded_amount    numeric
)
LANGUAGE plpgsql AS $$
DECLARE
  v_orig    sales%ROWTYPE;
  v_ticket  text;
BEGIN
  SELECT * INTO v_orig FROM sales s
  WHERE s.ticket_no = upper(trim(p_original_ticket)) AND s.quantity > 0
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'NOT_FOUND: sale % does not exist', p_original_ticket;
  END IF;
  IF v_orig.status IN ('refunded', 'exchanged') THEN
    RAISE EXCEPTION 'ALREADY_PROCESSED: sale % was already %', v_orig.ticket_no, v_orig.status;
  END IF;

  INSERT INTO sales AS s (user_hash, customer_name, contact, product_id, quantity, items,
                          base_amount, tax_amount, total_amount, shipping_fee, status,
                          sale_ref_ticket, comment)
  VALUES (v_orig.user_hash, v_orig.customer_name, v_orig.contact, v_orig.product_id,
          -v_orig.quantity, 'Refund: ' || v_orig.items,
          -v_orig.base_amount, -v_orig.tax_amount, -v_orig.total_amount, 0, 'refunded',
          v_orig.ticket_no, 'Refund of ' || v_orig.ticket_no || coalesce(': ' || p_reason, ''))
  RETURNING s.ticket_no INTO v_ticket;

  INSERT INTO returns (original_ticket, product_id, quantity, type, reason)
  VALUES (v_orig.ticket_no, v_orig.product_id, v_orig.quantity, 'refund', p_reason);

  UPDATE sales s SET status = 'refunded' WHERE s.sale_id = v_orig.sale_id;

  RETURN QUERY SELECT v_ticket, v_orig.ticket_no, v_orig.items, v_orig.total_amount;
END;
$$;


-- ---------------------------------------------------------------------
-- Exchange: the returned pair goes to the recovery partner and a new
-- sale is issued for the new pair (stock taken by the trigger).
-- price_difference > 0: the customer pays it; < 0: store credit.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION process_exchange(
  p_original_ticket text,
  p_new_product_id  bigint,
  p_reason          text
)
RETURNS TABLE (
  new_ticket        text,
  original_ticket   text,
  new_items         text,
  new_total         numeric,
  original_total    numeric,
  price_difference  numeric
)
LANGUAGE plpgsql AS $$
DECLARE
  v_orig     sales%ROWTYPE;
  v_product  catalog%ROWTYPE;
  v_total    numeric;
  v_base     numeric;
  v_items    text;
  v_ticket   text;
BEGIN
  SELECT * INTO v_orig FROM sales s
  WHERE s.ticket_no = upper(trim(p_original_ticket)) AND s.quantity > 0
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'NOT_FOUND: sale % does not exist', p_original_ticket;
  END IF;
  IF v_orig.status IN ('refunded', 'exchanged') THEN
    RAISE EXCEPTION 'ALREADY_PROCESSED: sale % was already %', v_orig.ticket_no, v_orig.status;
  END IF;

  SELECT * INTO v_product FROM catalog c WHERE c.product_id = p_new_product_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'NOT_FOUND: product % does not exist', p_new_product_id;
  END IF;

  INSERT INTO returns (original_ticket, product_id, quantity, type, reason)
  VALUES (v_orig.ticket_no, v_orig.product_id, v_orig.quantity, 'exchange', p_reason);

  v_total := v_product.price * v_orig.quantity;
  v_base  := round(v_total / (1 + setting_numeric('tax_rate')), 2);
  v_items := format('%s x %s %s (%s, %s)', v_orig.quantity, v_product.brand, v_product.model,
                    v_product.color, v_product.size_range);

  INSERT INTO sales AS s (user_hash, customer_name, contact, product_id, quantity, items,
                          base_amount, tax_amount, total_amount, shipping_fee,
                          sale_ref_ticket, comment)
  VALUES (v_orig.user_hash, v_orig.customer_name, v_orig.contact, p_new_product_id,
          v_orig.quantity, v_items, v_base, v_total - v_base, v_total, 0,
          v_orig.ticket_no, 'Exchange of ' || v_orig.ticket_no || coalesce(': ' || p_reason, ''))
  RETURNING s.ticket_no INTO v_ticket;

  UPDATE sales s SET status = 'exchanged' WHERE s.sale_id = v_orig.sale_id;

  RETURN QUERY SELECT v_ticket, v_orig.ticket_no, v_items, v_total, v_orig.total_amount,
                      v_total - v_orig.total_amount;
END;
$$;


-- ---------------------------------------------------------------------
-- Escalate to a person. The CHECK constraints on support_cases enforce
-- the hard rules; this function adds readable error codes and the
-- customer-facing case label (0001).
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION open_support_case(
  p_user_hash        text,
  p_customer_name    text,
  p_contact          text,
  p_reason           text,
  p_escalation_type  text,
  p_triage_area      text,
  p_ticket_no        text
)
RETURNS TABLE (
  case_id          bigint,
  case_label       text,
  escalation_type  text,
  triage_area      text
)
LANGUAGE plpgsql AS $$
DECLARE
  v_type  text := lower(trim(p_escalation_type));
  v_area  text := coalesce(nullif(lower(trim(p_triage_area)), ''), 'other');
  v_id    bigint;
BEGIN
  IF coalesce(trim(p_user_hash), '') = '' THEN
    RAISE EXCEPTION 'VALIDATION: user_hash is required';
  END IF;
  IF coalesce(trim(p_contact), '') = '' THEN
    RAISE EXCEPTION 'VALIDATION: a phone number or e-mail is required to open a case';
  END IF;
  IF v_type IS NULL OR v_type NOT IN ('supervisor_request', 'legal_mention', 'incomplete_delivery',
                                      'damaged_product', 'staff_complaint', 'other') THEN
    RAISE EXCEPTION 'VALIDATION: unknown escalation_type %', coalesce(p_escalation_type, 'NULL');
  END IF;
  IF v_area NOT IN ('product', 'store', 'staff', 'policies', 'other') THEN
    RAISE EXCEPTION 'VALIDATION: unknown triage_area %', p_triage_area;
  END IF;
  IF nullif(trim(p_ticket_no), '') IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM sales s WHERE s.ticket_no = upper(trim(p_ticket_no))) THEN
    RAISE EXCEPTION 'NOT_FOUND: sale % does not exist', p_ticket_no;
  END IF;

  INSERT INTO support_cases AS sc (user_hash, customer_name, contact, reason, escalation_type,
                                   triage_area, ticket_no)
  VALUES (p_user_hash, coalesce(nullif(trim(p_customer_name), ''), 'Anonymous'), trim(p_contact),
          p_reason, v_type, v_area, nullif(upper(trim(p_ticket_no)), ''))
  RETURNING sc.case_id INTO v_id;

  RETURN QUERY SELECT v_id,
                      CASE WHEN v_id > 9999 THEN v_id::text ELSE lpad(v_id::text, 4, '0') END,
                      v_type, v_area;
END;
$$;
