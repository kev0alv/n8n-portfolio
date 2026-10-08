#!/bin/sh
# Tests the operational database without touching real data:
#   1. builds a throwaway database (stride_soul_test) from postgres/sql
#   2. runs the functional tests in tests.sql
#   3. runs two concurrency tests with parallel sessions
#   4. drops the throwaway database
#
# From the repo folder:
#   docker compose exec postgres sh /tests/run.sh
set -eu

DB=stride_soul_test
PSQL="psql -v ON_ERROR_STOP=1 -X -q --username $POSTGRES_USER"

$PSQL -d n8n -c "DROP DATABASE IF EXISTS $DB" -c "CREATE DATABASE $DB OWNER sole_app"
for f in /sql/01_schema.sql /sql/02_seed.sql /sql/03_functions.sql; do
  $PSQL -d $DB -c "SET ROLE sole_app" -f "$f" >/dev/null
done

echo "== Functional tests"
fail=0
$PSQL -d $DB -c "SET ROLE sole_app" -f /tests/tests.sql || fail=1

echo "== Concurrency tests"

# C1: five customers try to buy the last pair at the same moment.
$PSQL -d $DB -c "UPDATE catalog SET stock = 1 WHERE product_id = 10" >/dev/null
for i in 1 2 3 4 5; do
  $PSQL -d $DB -tA -c "SELECT ticket_no FROM register_sale('race_$i', 'Racer', 'race@example.com', 10, 1)" \
    >/dev/null 2>&1 &
done
wait
sold=$($PSQL -d $DB -tA -c "SELECT count(*) FROM sales WHERE user_hash LIKE 'race_%'")
stock=$($PSQL -d $DB -tA -c "SELECT stock FROM catalog WHERE product_id = 10")
if [ "$sold" = "1" ] && [ "$stock" = "0" ]; then r=PASS; else r=FAIL; fail=1; fi
echo "C1 last pair, 5 buyers at once   expected: 1 sale, stock 0   got: $sold sale(s), stock $stock   $r"

# C2: the same receipt refunded twice at the same moment.
ticket=$($PSQL -d $DB -tA -c "SELECT ticket_no FROM register_sale('race_r', 'Racer', 'race@example.com', 28, 1)")
for i in 1 2; do
  $PSQL -d $DB -tA -c "SELECT process_refund('$ticket', 'race $i')" >/dev/null 2>&1 &
done
wait
notes=$($PSQL -d $DB -tA -c "SELECT count(*) FROM sales WHERE sale_ref_ticket = '$ticket' AND quantity < 0")
if [ "$notes" = "1" ]; then r=PASS; else r=FAIL; fail=1; fi
echo "C2 double refund at once          expected: 1 credit note        got: $notes                 $r"

$PSQL -d n8n -c "DROP DATABASE $DB"
exit $fail
