#!/bin/sh
# Builds n8n credentials from environment variables (so no secret is ever
# committed), then imports credentials and workflows into n8n's database.
set -eu

creds=/tmp/credentials.json

cat > "$creds" <<JSON
[
  {
    "id": "pgOpsWriter00001",
    "name": "Postgres ops (writer)",
    "type": "postgres",
    "data": {
      "host": "postgres", "port": 5432, "database": "ops",
      "user": "ops_writer", "password": "${OPS_WRITER_PASSWORD}",
      "ssl": "disable", "allowUnauthorizedCerts": false
    }
  },
  {
    "id": "pgOpsAnalyst0001",
    "name": "Postgres ops (read-only analyst)",
    "type": "postgres",
    "data": {
      "host": "postgres", "port": 5432, "database": "ops",
      "user": "ops_analyst", "password": "${OPS_ANALYST_PASSWORD}",
      "ssl": "disable", "allowUnauthorizedCerts": false
    }
  },
  {
    "id": "groqDemo00000001",
    "name": "Groq",
    "type": "groqApi",
    "data": { "apiKey": "${GROQ_API_KEY:-not-set}" }
  },
  {
    "id": "telegramDemo0001",
    "name": "Telegram alerts bot",
    "type": "telegramApi",
    "data": { "accessToken": "${TELEGRAM_BOT_TOKEN:-not-set}" }
  }
]
JSON

n8n import:credentials --input="$creds"
rm -f "$creds"

n8n import:workflow --separate --input=/workflows --activeState=fromJson

echo "Import finished."
