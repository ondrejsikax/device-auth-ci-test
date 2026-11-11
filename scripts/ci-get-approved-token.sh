#!/bin/sh
# Get a Keycloak access token that proves both:
#   1. this runs in GitLab CI (client auth = GitLab id_token $KC_JWT)
#   2. a user approved it (OAuth 2.0 device authorization grant)
# Prints the access token to stdout, everything else to stderr.
set -eu

: "${KC_ISSUER:?}" "${KC_CLIENT_ID:?}" "${KC_JWT:?}"

ASSERTION_TYPE=urn:ietf:params:oauth:client-assertion-type:jwt-bearer

kc() {
  curl -s "$KC_ISSUER/protocol/openid-connect/$1" \
    --data-urlencode "client_id=$KC_CLIENT_ID" \
    --data-urlencode "client_assertion_type=$ASSERTION_TYPE" \
    --data-urlencode "client_assertion=$KC_JWT" \
    "$@"
}

R=$(kc auth/device -d scope=openid)
DEVICE_CODE=$(echo "$R" | jq -r '.device_code // empty')
if [ -z "$DEVICE_CODE" ]; then
  echo "Device authorization failed: $R" >&2
  exit 1
fi
INTERVAL=$(echo "$R" | jq -r '.interval // 5')

{
  echo
  echo "=================================================="
  echo " Approval required for job: ${CI_JOB_URL:-?}"
  echo " Open: $(echo "$R" | jq -r .verification_uri_complete)"
  echo " Code: $(echo "$R" | jq -r .user_code)"
  echo "=================================================="
  echo
} >&2

while :; do
  sleep "$INTERVAL"
  R=$(kc token \
    -d grant_type=urn:ietf:params:oauth:grant-type:device_code \
    --data-urlencode "device_code=$DEVICE_CODE")
  ERR=$(echo "$R" | jq -r '.error // empty')
  case "$ERR" in
    "") echo "$R" | jq -r .access_token; exit 0 ;;
    authorization_pending) echo "Waiting for approval..." >&2 ;;
    slow_down) INTERVAL=$((INTERVAL + 5)) ;;
    *) echo "Failed: $ERR" >&2; exit 1 ;;
  esac
done
