-- =====================================================================
-- Stride & Soul — isolated tests of the transactional engine (no AI)
-- Run 5 of 5, after 01-04. Prints one PASS/FAIL row per test, then
-- removes everything it created and restores the stock it used.
--
-- Not covered here: two sales of the last pair at the same moment.
-- A console script runs statements one after another, so that test is
-- run from n8n with parallel executions in the testing phase.
-- =====================================================================

DECLARE results ARRAY<STRUCT<test STRING, expected STRING, got STRING, passed BOOL>> DEFAULT [];
DECLARE t_sale     STRING;
DECLARE t_exchange STRING;
DECLARE stock_before INT64;
DECLARE stock_after  INT64;

-- T1: valid sale takes one pair out of stock
SET stock_before = (SELECT stock FROM stride_soul.catalog WHERE product_id = 40);
BEGIN
  CALL stride_soul.sp_register_sale('test_t1', 'Test Buyer', 'buyer@example.com', 40, 1);
  SET stock_after = (SELECT stock FROM stride_soul.catalog WHERE product_id = 40);
  SET results = ARRAY_CONCAT(results, [STRUCT('T1 valid sale, stock -1', 'success',
      FORMAT('stock %d -> %d', stock_before, stock_after), stock_after = stock_before - 1)]);
EXCEPTION WHEN ERROR THEN
  SET results = ARRAY_CONCAT(results, [STRUCT('T1 valid sale, stock -1', 'success', @@error.message, FALSE)]);
END;
SET t_sale = (SELECT ticket_no FROM stride_soul.sales WHERE user_hash = 'test_t1' ORDER BY ticket_seq DESC LIMIT 1);

-- T2: invalid e-mail is rejected before anything is written
BEGIN
  CALL stride_soul.sp_register_sale('test_t2', 'Test', 'luis,prueba@gmail.com', 40, 1);
  SET results = ARRAY_CONCAT(results, [STRUCT('T2 invalid e-mail', 'VALIDATION', 'success', FALSE)]);
EXCEPTION WHEN ERROR THEN
  SET results = ARRAY_CONCAT(results, [STRUCT('T2 invalid e-mail', 'VALIDATION', @@error.message,
      REGEXP_CONTAINS(@@error.message, r'VALIDATION'))]);
END;

-- T3: more pairs than in stock is blocked, stock untouched
SET stock_before = (SELECT stock FROM stride_soul.catalog WHERE product_id = 10);
BEGIN
  CALL stride_soul.sp_register_sale('test_t3', 'Test', 'buyer@example.com', 10, 999);
  SET results = ARRAY_CONCAT(results, [STRUCT('T3 oversell blocked', 'OUT_OF_STOCK', 'success', FALSE)]);
EXCEPTION WHEN ERROR THEN
  SET stock_after = (SELECT stock FROM stride_soul.catalog WHERE product_id = 10);
  SET results = ARRAY_CONCAT(results, [STRUCT('T3 oversell blocked', 'OUT_OF_STOCK', @@error.message,
      REGEXP_CONTAINS(@@error.message, r'OUT_OF_STOCK') AND stock_after = stock_before)]);
END;

-- T4: unknown product
BEGIN
  CALL stride_soul.sp_register_sale('test_t4', 'Test', 'buyer@example.com', 9999, 1);
  SET results = ARRAY_CONCAT(results, [STRUCT('T4 unknown product', 'NOT_FOUND', 'success', FALSE)]);
EXCEPTION WHEN ERROR THEN
  SET results = ARRAY_CONCAT(results, [STRUCT('T4 unknown product', 'NOT_FOUND', @@error.message,
      REGEXP_CONTAINS(@@error.message, r'NOT_FOUND'))]);
END;

-- T5: refund issues a credit note and does NOT restore stock
SET stock_before = (SELECT stock FROM stride_soul.catalog WHERE product_id = 40);
BEGIN
  CALL stride_soul.sp_process_refund(t_sale, 'test refund');
  SET stock_after = (SELECT stock FROM stride_soul.catalog WHERE product_id = 40);
  SET results = ARRAY_CONCAT(results, [STRUCT('T5 refund, stock unchanged', 'success',
      FORMAT('stock %d -> %d', stock_before, stock_after), stock_after = stock_before)]);
EXCEPTION WHEN ERROR THEN
  SET results = ARRAY_CONCAT(results, [STRUCT('T5 refund, stock unchanged', 'success', @@error.message, FALSE)]);
END;

-- T6: the same sale cannot be refunded twice
BEGIN
  CALL stride_soul.sp_process_refund(t_sale, 'second attempt');
  SET results = ARRAY_CONCAT(results, [STRUCT('T6 double refund', 'ALREADY_PROCESSED', 'success', FALSE)]);
EXCEPTION WHEN ERROR THEN
  SET results = ARRAY_CONCAT(results, [STRUCT('T6 double refund', 'ALREADY_PROCESSED', @@error.message,
      REGEXP_CONTAINS(@@error.message, r'ALREADY_PROCESSED'))]);
END;

-- T7: exchange takes the new pair from stock and links both tickets
BEGIN
  CALL stride_soul.sp_register_sale('test_t7', 'Test Buyer', 'buyer@example.com', 38, 1);
  SET t_exchange = (SELECT ticket_no FROM stride_soul.sales WHERE user_hash = 'test_t7' ORDER BY ticket_seq DESC LIMIT 1);
  SET stock_before = (SELECT stock FROM stride_soul.catalog WHERE product_id = 39);
  CALL stride_soul.sp_process_exchange(t_exchange, 39, 'test exchange');
  SET stock_after = (SELECT stock FROM stride_soul.catalog WHERE product_id = 39);
  SET results = ARRAY_CONCAT(results, [STRUCT('T7 exchange, new pair -1', 'success',
      FORMAT('stock %d -> %d', stock_before, stock_after),
      stock_after = stock_before - 1
      AND (SELECT status FROM stride_soul.sales WHERE ticket_no = t_exchange) = 'exchanged')]);
EXCEPTION WHEN ERROR THEN
  SET results = ARRAY_CONCAT(results, [STRUCT('T7 exchange, new pair -1', 'success', @@error.message, FALSE)]);
END;

-- T8: support case without contact is rejected
BEGIN
  CALL stride_soul.sp_open_support_case('test_t8', 'Test', '', 'missing shoelaces', 'incomplete_delivery', 'product', NULL);
  SET results = ARRAY_CONCAT(results, [STRUCT('T8 case without contact', 'VALIDATION', 'success', FALSE)]);
EXCEPTION WHEN ERROR THEN
  SET results = ARRAY_CONCAT(results, [STRUCT('T8 case without contact', 'VALIDATION', @@error.message,
      REGEXP_CONTAINS(@@error.message, r'VALIDATION'))]);
END;

-- T9: valid support case gets a number
BEGIN
  CALL stride_soul.sp_open_support_case('test_t9', '', '+503 7000 0000', 'wants a supervisor', 'supervisor_request', NULL, NULL);
  SET results = ARRAY_CONCAT(results, [STRUCT('T9 valid support case', 'success', 'success',
      EXISTS(SELECT 1 FROM stride_soul.support_cases WHERE user_hash = 'test_t9' AND customer_name = 'Anonymous'))]);
EXCEPTION WHEN ERROR THEN
  SET results = ARRAY_CONCAT(results, [STRUCT('T9 valid support case', 'success', @@error.message, FALSE)]);
END;

-- T10: ticket numbers are never duplicated
SET results = ARRAY_CONCAT(results, [STRUCT('T10 tickets unique', 'no duplicates',
    FORMAT('%d tickets, %d distinct', (SELECT COUNT(*) FROM stride_soul.sales), (SELECT COUNT(DISTINCT ticket_no) FROM stride_soul.sales)),
    (SELECT COUNT(*) = COUNT(DISTINCT ticket_seq) FROM stride_soul.sales))]);

SELECT test, expected, got, IF(passed, 'PASS', 'FAIL') AS result FROM UNNEST(results);

-- ------------------------------------------------------------- cleanup
-- Give back the pairs the tests took, then delete the test rows.
UPDATE stride_soul.catalog c
SET stock = c.stock + t.pairs
FROM (
  SELECT product_id, SUM(quantity) AS pairs
  FROM stride_soul.sales
  WHERE STARTS_WITH(user_hash, 'test_') AND quantity > 0
  GROUP BY product_id
) t
WHERE c.product_id = t.product_id;

DELETE FROM stride_soul.returns
WHERE original_ticket IN (SELECT ticket_no FROM stride_soul.sales WHERE STARTS_WITH(user_hash, 'test_'));
DELETE FROM stride_soul.sales         WHERE STARTS_WITH(user_hash, 'test_');
DELETE FROM stride_soul.support_cases WHERE STARTS_WITH(user_hash, 'test_');

-- Counters go back to the highest number still in use.
UPDATE stride_soul.counters
SET value = IFNULL((SELECT MAX(ticket_seq) FROM stride_soul.sales), 0)
WHERE name = 'ticket';
UPDATE stride_soul.counters
SET value = IFNULL((SELECT MAX(case_id) FROM stride_soul.support_cases), 0)
WHERE name = 'support_case';
