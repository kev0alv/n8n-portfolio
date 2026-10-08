-- =====================================================================
-- Stride & Soul — isolated tests of the operational database (no AI).
-- Run by postgres/tests/run.sh against a throwaway copy of the schema.
-- Prints one PASS/FAIL row per test.
-- =====================================================================
\set ON_ERROR_STOP on

CREATE TEMP TABLE results (n serial, test text, expected text, got text, passed boolean);

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
LANGUAGE sql AS $$ INSERT INTO results (test, expected, got, passed) VALUES (p_test, p_expected, p_got, p_ok) $$;

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
SELECT pg_temp.check('T6 refund (credit note, stock unchanged)',
  'credit note for SS-000001, -$88, stock 8',
  format('credit note for %s, -$%s, stock %s', original_ticket, refunded_amount,
         (SELECT stock FROM catalog WHERE product_id = 40)),
  original_ticket = 'SS-000001' AND refunded_amount = 88
    AND (SELECT stock FROM catalog WHERE product_id = 40) = 8
    AND (SELECT total_amount FROM sales WHERE ticket_no = credit_note_ticket) = -88)
FROM process_refund('ss-000001', 'test refund');

-- T7 the same receipt cannot be refunded twice
SELECT pg_temp.expect_error('T7 double refund', 'ALREADY_PROCESSED',
  $$SELECT process_refund('SS-000001', 'again')$$);

-- T8 exchange: new pair taken from stock, both receipts linked, difference computed
SELECT ticket_no AS exch_ticket FROM register_sale('t_user8', 'Test', 'buyer@example.com', 38, 1) \gset
SELECT pg_temp.check('T8 exchange', 'new pair stock 7 -> 6, difference +15',
  format('new pair stock -> %s, difference %s', (SELECT stock FROM catalog WHERE product_id = 39), price_difference),
  (SELECT stock FROM catalog WHERE product_id = 39) = 6 AND price_difference = 15
    AND (SELECT status FROM sales WHERE ticket_no = :'exch_ticket') = 'exchanged')
FROM process_exchange(:'exch_ticket', 39, 'test exchange');

-- T9 support case without contact is rejected
SELECT pg_temp.expect_error('T9 case without contact', 'VALIDATION',
  $$SELECT open_support_case('t_user9', 'Test', '  ', 'missing laces', 'incomplete_delivery', 'product', NULL)$$);

-- T10 valid support case: anonymous name, label 0001
SELECT pg_temp.check('T10 valid support case', 'label 0001, Anonymous, area other',
  format('label %s, %s, area %s', case_label,
         (SELECT customer_name FROM support_cases sc WHERE sc.case_id = o.case_id), triage_area),
  case_label = '0001' AND triage_area = 'other')
FROM open_support_case('t_user10', '', '+503 7000 0000', 'wants a supervisor', 'supervisor_request', NULL, NULL) o;

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
