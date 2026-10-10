#!/bin/sh
# 1. Creates the n8n owner account on first boot.
# 2. Publishes (activates) the workflows listed in ACTIVATE_WORKFLOWS.
# Both steps need n8n's REST API, so this runs after n8n reports ready.
set -eu

api=http://n8n:5678/rest
headers=/tmp/login-headers

# /healthz/readiness can answer before every route is mounted: retry briefly.
setup_owner() {
  body=$(printf '{"email":"%s","firstName":"Kevin","lastName":"Alvarez","password":"%s"}' \
    "$N8N_OWNER_EMAIL" "$N8N_OWNER_PASSWORD")
  for i in 1 2 3 4 5 6 7 8 9 10; do
    code=$(curl -s -o /tmp/resp -w '%{http_code}' -H 'Content-Type: application/json' \
      -d "$body" "$api/owner/setup")
    case "$code" in
      200) echo "Owner account created: $N8N_OWNER_EMAIL"; return 0 ;;
      400) echo "Owner already exists."; return 0 ;;
    esac
    sleep 3
  done
  echo "Owner setup failed (HTTP $code):"; cat /tmp/resp; return 1
}

login() {
  body=$(printf '{"emailOrLdapLoginId":"%s","password":"%s"}' "$N8N_OWNER_EMAIL" "$N8N_OWNER_PASSWORD")
  code=$(curl -s -D "$headers" -o /tmp/resp -w '%{http_code}' -H 'Content-Type: application/json' \
    -d "$body" "$api/login")
  [ "$code" = "200" ] || { echo "Login failed (HTTP $code):"; cat /tmp/resp; return 1; }
  # n8n marks its session cookie Secure, and curl neither stores nor sends Secure
  # cookies over plain http unless the host is "localhost". Inside Docker the host
  # is "n8n", so read the cookie from the Set-Cookie header and send it by hand.
  auth="Cookie: $(sed -n 's/^[Ss]et-[Cc]ookie: \(n8n-auth=[^;]*\).*/\1/p' "$headers")"
}

publish() {
  id=$1
  # The current versionId is required to publish.
  version=$(curl -s -H "$auth" "$api/workflows/$id" | sed -n 's/.*"versionId":"\([^"]*\)".*/\1/p' | head -1)
  if [ -z "$version" ]; then
    echo "Workflow $id not found, skipping."; return 0
  fi
  code=$(curl -s -H "$auth" -o /tmp/resp -w '%{http_code}' -H 'Content-Type: application/json' \
    -d "{\"versionId\":\"$version\"}" "$api/workflows/$id/activate")
  if [ "$code" = "200" ]; then echo "Published $id"; else echo "Could not publish $id (HTTP $code):"; cat /tmp/resp; echo; fi
}

setup_owner
if [ -n "${ACTIVATE_WORKFLOWS:-}" ]; then
  login
  for id in $ACTIVATE_WORKFLOWS; do publish "$id"; done
fi
echo "Setup finished."
