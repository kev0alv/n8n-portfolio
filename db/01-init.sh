#!/bin/sh
# Runs once, on the first start of an empty Postgres volume.
# Creates the "ops" database (the demo data warehouse), two roles and the schema.
#   ops_writer  - used by n8n pipelines (insert/select)
#   ops_analyst - read-only, used by the AI agent and Grafana
set -eu

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<SQL
CREATE ROLE ops_writer  LOGIN PASSWORD '${OPS_WRITER_PASSWORD}';
CREATE ROLE ops_analyst LOGIN PASSWORD '${OPS_ANALYST_PASSWORD}';
CREATE DATABASE ops OWNER ops_writer;
SQL

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname ops \
  -f /docker-entrypoint-initdb.d/sql/schema.sql \
  -f /docker-entrypoint-initdb.d/sql/seed.sql
