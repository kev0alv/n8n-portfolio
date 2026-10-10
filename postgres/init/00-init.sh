#!/bin/sh
# Runs once, on the first start of an empty Postgres volume.
# Creates the operational database "stride_soul", owned by the role the
# workflows use (sole_app), and loads schema, seed data and functions.
# n8n's own database ("n8n") lives in the same server but is separate.
set -eu

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname n8n <<SQL
CREATE ROLE sole_app LOGIN PASSWORD '${SOLE_APP_PASSWORD}';
CREATE DATABASE stride_soul OWNER sole_app;
SQL

for f in /sql/01_schema.sql /sql/02_seed.sql /sql/03_functions.sql; do
  echo "Loading $f"
  psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname stride_soul \
    -c "SET ROLE sole_app" -f "$f"
done
