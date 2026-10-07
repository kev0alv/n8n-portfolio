#!/bin/sh
# Imports credentials (built from .env and secrets/) and the workflows in
# n8n/workflows into n8n's database. Runs on every `docker compose up`, so
# the repo stays the source of truth. Export changes made in the editor
# back to n8n/workflows before restarting, or they are overwritten.
set -eu

creds=/tmp/credentials.json
node /init/build-credentials.js "$creds"
if [ "$(cat "$creds")" != "[]" ]; then
  n8n import:credentials --input="$creds"
fi
rm -f "$creds"

if ls /workflows/*.json >/dev/null 2>&1; then
  n8n import:workflow --separate --input=/workflows
else
  echo "No workflows in n8n/workflows yet, skipping."
fi

echo "Import finished."
