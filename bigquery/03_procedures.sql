-- =====================================================================
-- Stride & Soul — stored procedures (the transactional engine)
-- Run 3 of 5. Safe to re-run (CREATE OR REPLACE).
--
-- What replaced what (Supabase -> BigQuery):
--   trigger fn_descuenta_stock + FOR UPDATE  -> sp_register_sale: guarded
--                                              UPDATE inside a transaction
--   SEQUENCE seq_ticket_fcf                  -> counters table, row 'ticket'
--   CHECK constraints                        -> validations that RAISE
--   atomic refund CTE                        -> sp_process_refund
--
-- Concurrency: BigQuery aborts one of two transactions that modify the
-- same table at the same time ("Transaction is aborted due to concurrent
-- update"). Nothing is written by the aborted one, so the caller (n8n)
-- simply retries. That is what prevents overselling and duplicate numbers.
--
-- Every procedure ends with a SELECT: that row is what n8n receives.
-- Errors start with a code (VALIDATION, NOT_FOUND, OUT_OF_STOCK,
-- ALREADY_PROCESSED) so the agent can explain them to the customer.
-- =====================================================================


-- ---------------------------------------------------------------------
-- Register a sale of one product variant.
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE stride_soul.sp_register_sale(
  p_user_hash      STRING,
  p_customer_name  STRING,
  p_contact        STRING,   -- e-mail, already validated by regex in n8n; checked again here
  p_product_id     INT64,
  p_quantity       INT64
)
BEGIN
  DECLARE v_tax_rate     NUMERIC;
  DECLARE v_prefix       STRING;
  DECLARE v_fee          NUMERIC;
  DECLARE v_free_pairs   INT64;
  DECLARE v_stock        INT64;
  DECLARE v_price        NUMERIC;
  DECLARE v_items        STRING;
  DECLARE v_seq          INT64;
  DECLARE v_ticket       STRING;
  DECLARE v_total        NUMERIC;
  DECLARE v_base         NUMERIC;
  DECLARE v_shipping     NUMERIC;

  -- Deterministic validation first: no transaction is opened for bad input.
  IF p_user_hash IS NULL OR TRIM(p_user_hash) = '' THEN
    RAISE USING MESSAGE = 'VALIDATION: user_hash is required';
  END IF;
  IF p_quantity IS NULL OR p_quantity <= 0 THEN
    RAISE USING MESSAGE = 'VALIDATION: quantity must be at least 1';
  END IF;
  IF p_contact IS NULL OR NOT REGEXP_CONTAINS(TRIM(p_contact), r'^[^@\s,;]+@[^@\s,;]+\.[A-Za-z]{2,}$') THEN
    RAISE USING MESSAGE = 'VALIDATION: a valid e-mail is required to issue the receipt';
  END IF;

  SET v_tax_rate   = (SELECT CAST(value AS NUMERIC) FROM stride_soul.settings WHERE key = 'tax_rate');
  SET v_prefix     = (SELECT value FROM stride_soul.settings WHERE key = 'ticket_prefix');
  SET v_fee        = (SELECT CAST(value AS NUMERIC) FROM stride_soul.settings WHERE key = 'shipping_fee');
  SET v_free_pairs = (SELECT CAST(value AS INT64) FROM stride_soul.settings WHERE key = 'free_shipping_min_pairs');

  BEGIN
    BEGIN TRANSACTION;

    SET v_stock = (SELECT stock FROM stride_soul.catalog WHERE product_id = p_product_id);
    SET v_price = (SELECT price FROM stride_soul.catalog WHERE product_id = p_product_id);
    SET v_items = (SELECT FORMAT('%d x %s %s (%s, %s)', p_quantity, brand, model, color, size_range)
                   FROM stride_soul.catalog WHERE product_id = p_product_id);

    IF v_stock IS NULL THEN
      RAISE USING MESSAGE = FORMAT('NOT_FOUND: product %d does not exist', p_product_id);
    END IF;
    IF v_stock < p_quantity THEN
      RAISE USING MESSAGE = FORMAT('OUT_OF_STOCK: product %d has %d left, %d requested', p_product_id, v_stock, p_quantity);
    END IF;

    -- Guarded update: also protects against a manual change in between.
    UPDATE stride_soul.catalog
    SET stock = stock - p_quantity
    WHERE product_id = p_product_id AND stock >= p_quantity;
    IF @@row_count <> 1 THEN
      RAISE USING MESSAGE = FORMAT('OUT_OF_STOCK: product %d', p_product_id);
    END IF;

    UPDATE stride_soul.counters SET value = value + 1 WHERE name = 'ticket';
    SET v_seq    = (SELECT value FROM stride_soul.counters WHERE name = 'ticket');
    SET v_ticket = CONCAT(v_prefix, LPAD(CAST(v_seq AS STRING), 6, '0'));

    -- Catalog prices already include tax: split it out.
    SET v_total    = v_price * p_quantity;
    SET v_base     = ROUND(v_total / (1 + v_tax_rate), 2);
    SET v_shipping = IF(p_quantity >= v_free_pairs, 0, v_fee);

    INSERT INTO stride_soul.sales (
      sale_id, ticket_seq, ticket_no, user_hash, customer_name, contact, product_id, quantity,
      items, base_amount, tax_amount, total_amount, shipping_fee, status, sale_ref_ticket, comment, created_at)
    VALUES (
      GENERATE_UUID(), v_seq, v_ticket, p_user_hash,
      COALESCE(NULLIF(TRIM(p_customer_name), ''), 'Anonymous'), TRIM(p_contact),
      p_product_id, p_quantity, v_items,
      v_base, v_total - v_base, v_total, v_shipping, 'validated', NULL, NULL, CURRENT_TIMESTAMP());

    COMMIT TRANSACTION;
  EXCEPTION WHEN ERROR THEN
    ROLLBACK TRANSACTION;
    RAISE USING MESSAGE = @@error.message;
  END;

  SELECT
    v_ticket                AS ticket_no,
    v_items                 AS items,
    v_base                  AS base_amount,
    v_total - v_base        AS tax_amount,
    v_total                 AS total_amount,
    v_shipping              AS shipping_fee,
    v_total + v_shipping    AS amount_to_pay,
    v_stock - p_quantity    AS stock_left;
END;


-- ---------------------------------------------------------------------
-- Full refund of a sale: credit note (negative sale) + returned pair.
-- Stock is NOT restored: a returned pair goes to the recovery partner.
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE stride_soul.sp_process_refund(
  p_original_ticket STRING,
  p_reason          STRING
)
BEGIN
  DECLARE v_prefix  STRING;
  DECLARE v_orig    STRUCT<user_hash STRING, customer_name STRING, contact STRING, product_id INT64,
                           quantity INT64, items STRING, base_amount NUMERIC, tax_amount NUMERIC,
                           total_amount NUMERIC, status STRING>;
  DECLARE v_seq     INT64;
  DECLARE v_ticket  STRING;

  IF p_original_ticket IS NULL OR TRIM(p_original_ticket) = '' THEN
    RAISE USING MESSAGE = 'VALIDATION: original ticket is required';
  END IF;

  SET v_prefix = (SELECT value FROM stride_soul.settings WHERE key = 'ticket_prefix');

  BEGIN
    BEGIN TRANSACTION;

    SET v_orig = (
      SELECT AS STRUCT user_hash, customer_name, contact, product_id, quantity, items,
                       base_amount, tax_amount, total_amount, status
      FROM stride_soul.sales
      WHERE ticket_no = UPPER(TRIM(p_original_ticket)) AND quantity > 0);

    IF v_orig IS NULL THEN
      RAISE USING MESSAGE = FORMAT('NOT_FOUND: sale %s does not exist', p_original_ticket);
    END IF;
    IF v_orig.status IN ('refunded', 'exchanged') THEN
      RAISE USING MESSAGE = FORMAT('ALREADY_PROCESSED: sale %s was already %s', p_original_ticket, v_orig.status);
    END IF;

    UPDATE stride_soul.counters SET value = value + 1 WHERE name = 'ticket';
    SET v_seq    = (SELECT value FROM stride_soul.counters WHERE name = 'ticket');
    SET v_ticket = CONCAT(v_prefix, LPAD(CAST(v_seq AS STRING), 6, '0'));

    INSERT INTO stride_soul.sales (
      sale_id, ticket_seq, ticket_no, user_hash, customer_name, contact, product_id, quantity,
      items, base_amount, tax_amount, total_amount, shipping_fee, status, sale_ref_ticket, comment, created_at)
    VALUES (
      GENERATE_UUID(), v_seq, v_ticket, v_orig.user_hash, v_orig.customer_name, v_orig.contact,
      v_orig.product_id, -v_orig.quantity, CONCAT('Refund: ', v_orig.items),
      -v_orig.base_amount, -v_orig.tax_amount, -v_orig.total_amount, 0,
      'refunded', UPPER(TRIM(p_original_ticket)),
      CONCAT('Refund of ', UPPER(TRIM(p_original_ticket)), IF(p_reason IS NULL, '', CONCAT(': ', p_reason))),
      CURRENT_TIMESTAMP());

    INSERT INTO stride_soul.returns (
      return_id, original_ticket, product_id, quantity, type, destination, reason, created_at)
    VALUES (
      GENERATE_UUID(), UPPER(TRIM(p_original_ticket)), v_orig.product_id, v_orig.quantity,
      'refund', 'recovery_partner', p_reason, CURRENT_TIMESTAMP());

    UPDATE stride_soul.sales SET status = 'refunded'
    WHERE ticket_no = UPPER(TRIM(p_original_ticket)) AND quantity > 0;

    COMMIT TRANSACTION;
  EXCEPTION WHEN ERROR THEN
    ROLLBACK TRANSACTION;
    RAISE USING MESSAGE = @@error.message;
  END;

  SELECT
    v_ticket                    AS credit_note_ticket,
    UPPER(TRIM(p_original_ticket)) AS original_ticket,
    v_orig.items                AS items,
    v_orig.total_amount         AS refunded_amount;
END;


-- ---------------------------------------------------------------------
-- Exchange: the returned pair goes to the recovery partner and a new
-- sale is issued for the new pair (stock is taken from the new product).
-- price_difference > 0: the customer pays it; < 0: store credit.
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE stride_soul.sp_process_exchange(
  p_original_ticket STRING,
  p_new_product_id  INT64,
  p_reason          STRING
)
BEGIN
  DECLARE v_tax_rate  NUMERIC;
  DECLARE v_prefix    STRING;
  DECLARE v_orig      STRUCT<user_hash STRING, customer_name STRING, contact STRING, product_id INT64,
                             quantity INT64, total_amount NUMERIC, status STRING>;
  DECLARE v_stock     INT64;
  DECLARE v_price     NUMERIC;
  DECLARE v_items     STRING;
  DECLARE v_seq       INT64;
  DECLARE v_ticket    STRING;
  DECLARE v_total     NUMERIC;
  DECLARE v_base      NUMERIC;

  IF p_original_ticket IS NULL OR TRIM(p_original_ticket) = '' THEN
    RAISE USING MESSAGE = 'VALIDATION: original ticket is required';
  END IF;

  SET v_tax_rate = (SELECT CAST(value AS NUMERIC) FROM stride_soul.settings WHERE key = 'tax_rate');
  SET v_prefix   = (SELECT value FROM stride_soul.settings WHERE key = 'ticket_prefix');

  BEGIN
    BEGIN TRANSACTION;

    SET v_orig = (
      SELECT AS STRUCT user_hash, customer_name, contact, product_id, quantity, total_amount, status
      FROM stride_soul.sales
      WHERE ticket_no = UPPER(TRIM(p_original_ticket)) AND quantity > 0);

    IF v_orig IS NULL THEN
      RAISE USING MESSAGE = FORMAT('NOT_FOUND: sale %s does not exist', p_original_ticket);
    END IF;
    IF v_orig.status IN ('refunded', 'exchanged') THEN
      RAISE USING MESSAGE = FORMAT('ALREADY_PROCESSED: sale %s was already %s', p_original_ticket, v_orig.status);
    END IF;

    SET v_stock = (SELECT stock FROM stride_soul.catalog WHERE product_id = p_new_product_id);
    SET v_price = (SELECT price FROM stride_soul.catalog WHERE product_id = p_new_product_id);
    SET v_items = (SELECT FORMAT('%d x %s %s (%s, %s)', v_orig.quantity, brand, model, color, size_range)
                   FROM stride_soul.catalog WHERE product_id = p_new_product_id);

    IF v_stock IS NULL THEN
      RAISE USING MESSAGE = FORMAT('NOT_FOUND: product %d does not exist', p_new_product_id);
    END IF;
    IF v_stock < v_orig.quantity THEN
      RAISE USING MESSAGE = FORMAT('OUT_OF_STOCK: product %d has %d left, %d requested', p_new_product_id, v_stock, v_orig.quantity);
    END IF;

    UPDATE stride_soul.catalog
    SET stock = stock - v_orig.quantity
    WHERE product_id = p_new_product_id AND stock >= v_orig.quantity;
    IF @@row_count <> 1 THEN
      RAISE USING MESSAGE = FORMAT('OUT_OF_STOCK: product %d', p_new_product_id);
    END IF;

    INSERT INTO stride_soul.returns (
      return_id, original_ticket, product_id, quantity, type, destination, reason, created_at)
    VALUES (
      GENERATE_UUID(), UPPER(TRIM(p_original_ticket)), v_orig.product_id, v_orig.quantity,
      'exchange', 'recovery_partner', p_reason, CURRENT_TIMESTAMP());

    UPDATE stride_soul.counters SET value = value + 1 WHERE name = 'ticket';
    SET v_seq    = (SELECT value FROM stride_soul.counters WHERE name = 'ticket');
    SET v_ticket = CONCAT(v_prefix, LPAD(CAST(v_seq AS STRING), 6, '0'));

    SET v_total = v_price * v_orig.quantity;
    SET v_base  = ROUND(v_total / (1 + v_tax_rate), 2);

    INSERT INTO stride_soul.sales (
      sale_id, ticket_seq, ticket_no, user_hash, customer_name, contact, product_id, quantity,
      items, base_amount, tax_amount, total_amount, shipping_fee, status, sale_ref_ticket, comment, created_at)
    VALUES (
      GENERATE_UUID(), v_seq, v_ticket, v_orig.user_hash, v_orig.customer_name, v_orig.contact,
      p_new_product_id, v_orig.quantity, v_items,
      v_base, v_total - v_base, v_total, 0, 'validated', UPPER(TRIM(p_original_ticket)),
      CONCAT('Exchange of ', UPPER(TRIM(p_original_ticket)), IF(p_reason IS NULL, '', CONCAT(': ', p_reason))),
      CURRENT_TIMESTAMP());

    UPDATE stride_soul.sales SET status = 'exchanged'
    WHERE ticket_no = UPPER(TRIM(p_original_ticket)) AND quantity > 0;

    COMMIT TRANSACTION;
  EXCEPTION WHEN ERROR THEN
    ROLLBACK TRANSACTION;
    RAISE USING MESSAGE = @@error.message;
  END;

  SELECT
    v_ticket                          AS new_ticket,
    UPPER(TRIM(p_original_ticket))    AS original_ticket,
    v_items                           AS new_items,
    v_total                           AS new_total,
    v_orig.total_amount               AS original_total,
    v_total - v_orig.total_amount     AS price_difference;
END;


-- ---------------------------------------------------------------------
-- Escalate to a person. Hard rule: no contact, no case.
-- ---------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE stride_soul.sp_open_support_case(
  p_user_hash        STRING,
  p_customer_name    STRING,
  p_contact          STRING,   -- phone or e-mail
  p_reason           STRING,
  p_escalation_type  STRING,
  p_triage_area      STRING,
  p_ticket_no        STRING    -- optional
)
BEGIN
  DECLARE v_case_id  INT64;
  DECLARE v_type     STRING DEFAULT LOWER(TRIM(p_escalation_type));
  DECLARE v_area     STRING DEFAULT COALESCE(NULLIF(LOWER(TRIM(p_triage_area)), ''), 'other');

  IF p_user_hash IS NULL OR TRIM(p_user_hash) = '' THEN
    RAISE USING MESSAGE = 'VALIDATION: user_hash is required';
  END IF;
  IF p_contact IS NULL OR TRIM(p_contact) = '' THEN
    RAISE USING MESSAGE = 'VALIDATION: a phone number or e-mail is required to open a case';
  END IF;
  IF v_type IS NULL OR v_type NOT IN
     ('supervisor_request', 'legal_mention', 'incomplete_delivery', 'damaged_product', 'staff_complaint', 'other') THEN
    RAISE USING MESSAGE = FORMAT('VALIDATION: unknown escalation_type %s', IFNULL(p_escalation_type, 'NULL'));
  END IF;
  IF v_area NOT IN ('product', 'store', 'staff', 'policies', 'other') THEN
    RAISE USING MESSAGE = FORMAT('VALIDATION: unknown triage_area %s', p_triage_area);
  END IF;

  BEGIN
    BEGIN TRANSACTION;

    UPDATE stride_soul.counters SET value = value + 1 WHERE name = 'support_case';
    SET v_case_id = (SELECT value FROM stride_soul.counters WHERE name = 'support_case');

    INSERT INTO stride_soul.support_cases (
      case_id, user_hash, customer_name, contact, reason, escalation_type, triage_area,
      ticket_no, attended, created_at)
    VALUES (
      v_case_id, p_user_hash, COALESCE(NULLIF(TRIM(p_customer_name), ''), 'Anonymous'), TRIM(p_contact),
      p_reason, v_type, v_area, NULLIF(UPPER(TRIM(p_ticket_no)), ''), FALSE, CURRENT_TIMESTAMP());

    COMMIT TRANSACTION;
  EXCEPTION WHEN ERROR THEN
    ROLLBACK TRANSACTION;
    RAISE USING MESSAGE = @@error.message;
  END;

  SELECT
    v_case_id                                                        AS case_id,
    IF(v_case_id > 9999, CAST(v_case_id AS STRING), LPAD(CAST(v_case_id AS STRING), 4, '0')) AS case_label,
    v_type                                                           AS escalation_type,
    v_area                                                           AS triage_area;
END;
