-- =====================================================================
-- Stride & Soul — isolated tests of the operational database (no AI).
-- Run by postgres/tests/run.sh against a throwaway copy of the schema.
-- Prints one PASS/FAIL row per test.
-- =====================================================================
\set ON_ERROR_STOP on

CREATE TEMP TABLE results (n serial, test text, expected text, got text, passed boolean);

-- Note: a query does not see rows written by a function it calls (same snapshot),
-- so each operation runs first and is verified in a separate statement.

-- Runs a statement that must fail and records whether it failed with the expected code.
CREATE FUNCTION pg_temp.expect_error(p_test text, p_code text, p_sql text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  EXECUTE p_sql;
  INSERT INTO results (test, expected, got, passed) VALUES (p_test, p_code, 'no error', false);
EXCEPTION WHEN OTHERS THEN
  INSERT INTO results (test, expected, got, passed) VALUES (p_test, p_code, SQLERRM, SQLERRM LIKE p_code || '%');
END $$;

CREATE FUNCTION pg_temp.check(p_test text, p_expected text, p_got text, p_ok boolean) RETURNS void
LANGUAGE sql AS $$ INSERT INTO results (test, expected, got, passed) VALUES (p_test, p_expected, coalesce(p_got, 'NULL'), coalesce(p_ok, false)) $$;

-- T1 valid sale: receipt issued, stock -1, tax split, shipping charged for 1 pair
SELECT pg_temp.check('T1 valid sale',
  'SS-000001, stock 9 -> 8, $88 = 77.88 + 10.12, ship 2',
  format('%s, stock %s, $%s = %s + %s, ship %s', ticket_no, stock_left, total_amount, base_amount, tax_amount, shipping_fee),
  ticket_no = 'SS-000001' AND stock_left = 8 AND total_amount = 88 AND base_amount = 77.88
    AND tax_amount = 10.12 AND shipping_fee = 2)
FROM register_sale('t_user1', 'Test Buyer', 'buyer@example.com', 40, 1);

-- T2 two pairs ship free
SELECT pg_temp.check('T2 two pairs ship free', 'ship 0', 'ship ' || shipping_fee, shipping_fee = 0)
FROM register_sale('t_user2', 'Test Buyer', 'buyer@example.com', 33, 2);

-- T3 invalid e-mail (the one that broke Djanne in testing)
SELECT pg_temp.expect_error('T3 invalid e-mail', 'VALIDATION',
  $$SELECT register_sale('t_user3', 'Luis', 'luis,prueba@gmail.com', 40, 1)$$);

-- T4 more pairs than in stock: blocked by the trigger, stock untouched
SELECT pg_temp.expect_error('T4 oversell blocked', 'OUT_OF_STOCK',
  $$SELECT register_sale('t_user4', 'Test', 'buyer@example.com', 10, 999)$$);
SELECT pg_temp.check('T4b stock untouched', 'stock 3', 'stock ' || stock, stock = 3)
FROM catalog WHERE product_id = 10;

-- T5 unknown product
SELECT pg_temp.expect_error('T5 unknown product', 'NOT_FOUND',
  $$SELECT register_sale('t_user5', 'Test', 'buyer@example.com', 9999, 1)$$);

-- T6 refund: credit note linked to the original, stock NOT restored
SELECT credit_note_ticket AS refund_note, refunded_amount AS refund_amount
FROM process_refund('ss-000001', 'test refund') \gset
SELECT pg_temp.check('T6 refund (credit note, stock unchanged)',
  'credit note -88.00 for SS-000001, original refunded, stock 8',
  format('credit note %s for %s, original %s, stock %s', n.total_amount, n.sale_ref_ticket, o.status, c.stock),
  :refund_amount = 88 AND n.total_amount = -88 AND n.quantity = -1 AND n.sale_ref_ticket = 'SS-000001'
    AND o.status = 'refunded' AND c.stock = 8
    AND EXISTS (SELECT 1 FROM returns r WHERE r.original_ticket = 'SS-000001' AND r.type = 'refund'))
FROM sales n, sales o, catalog c
WHERE n.ticket_no = :'refund_note' AND o.ticket_no = 'SS-000001' AND c.product_id = 40;

-- T7 the same receipt cannot be refunded twice
SELECT pg_temp.expect_error('T7 double refund', 'ALREADY_PROCESSED',
  $$SELECT process_refund('SS-000001', 'again')$$);

-- T8 exchange: new pair taken from stock, both receipts linked, difference computed
SELECT ticket_no AS exch_ticket FROM register_sale('t_user8', 'Test', 'buyer@example.com', 38, 1) \gset
SELECT new_ticket AS exch_new, price_difference AS exch_diff
FROM process_exchange(:'exch_ticket', 39, 'test exchange') \gset
SELECT pg_temp.check('T8 exchange', 'new pair stock 7 -> 6, difference 15.00, original exchanged',
  format('new pair stock -> %s, difference %s, original %s', c.stock, :'exch_diff', o.status),
  c.stock = 6 AND :exch_diff = 15 AND o.status = 'exchanged' AND n.sale_ref_ticket = :'exch_ticket'
    AND EXISTS (SELECT 1 FROM returns r WHERE r.original_ticket = :'exch_ticket' AND r.type = 'exchange'))
FROM catalog c, sales o, sales n
WHERE c.product_id = 39 AND o.ticket_no = :'exch_ticket' AND n.ticket_no = :'exch_new';

-- T9 support case without contact is rejected
SELECT pg_temp.expect_error('T9 case without contact', 'VALIDATION',
  $$SELECT open_support_case('t_user9', 'Test', '  ', 'missing laces', 'incomplete_delivery', 'product', NULL)$$);

-- T10 valid support case: anonymous name, label 0001
SELECT case_id AS case_id, case_label AS case_label
FROM open_support_case('t_user10', '', '+503 7000 0000', 'wants a supervisor', 'supervisor_request', NULL, NULL) \gset
SELECT pg_temp.check('T10 valid support case', 'label 0001, Anonymous, area other',
  format('label %s, %s, area %s', :'case_label', customer_name, triage_area),
  :'case_label' = '0001' AND customer_name = 'Anonymous' AND triage_area = 'other' AND NOT attended)
FROM support_cases WHERE case_id = :case_id;

-- T11 unknown escalation type
SELECT pg_temp.expect_error('T11 unknown escalation type', 'VALIDATION',
  $$SELECT open_support_case('t_user11', 'Test', 'a@b.co', 'x', 'angry', NULL, NULL)$$);

-- T12 a credit note can never carry positive amounts (CHECK constraint)
SELECT pg_temp.expect_error('T12 sign constraint', 'new row for relation "sales" violates check constraint',
  $$INSERT INTO sales (user_hash, quantity, items, base_amount, tax_amount, total_amount)
    VALUES ('t_user12', -1, 'bad', 10, 1.3, 11.3)$$);

SELECT n AS "#", test, expected, got, CASE WHEN passed THEN 'PASS' ELSE 'FAIL' END AS result
FROM results ORDER BY n;

SELECT CASE WHEN bool_and(passed) THEN 'ALL ' || count(*) || ' TESTS PASSED'
            ELSE (count(*) FILTER (WHERE NOT passed)) || ' TEST(S) FAILED' END AS summary
FROM results;

-- Make the run fail (non-zero exit) when any test failed.
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM results WHERE NOT passed) THEN
    RAISE EXCEPTION 'functional tests failed';
  END IF;
END $$;
