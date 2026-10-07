#!/bin/sh
# Creates the n8n owner account on first boot. On later boots n8n answers
# "owner already set up" and this exits cleanly.
set -eu

body=$(printf '{"email":"%s","firstName":"Demo","lastName":"Owner","password":"%s"}' \
  "$N8N_OWNER_EMAIL" "$N8N_OWNER_PASSWORD")

code=$(curl -s -o /tmp/resp -w '%{http_code}' \
  -H 'Content-Type: application/json' -d "$body" \
  http://n8n:5678/rest/owner/setup)

case "$code" in
  200) echo "Owner account created: $N8N_OWNER_EMAIL" ;;
  400) echo "Owner already exists, nothing to do." ;;
  *)   echo "Owner setup returned HTTP $code:"; cat /tmp/resp; exit 1 ;;
esac
