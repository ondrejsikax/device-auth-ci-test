#!/bin/sh
# Log in to Vault with the approved Keycloak Access Token and read a secret.
# Usage: ci-read-vault-secret.sh <token-file>
set -eu

: "${VAULT_ADDR:?}" "${VAULT_ROLE:?}" "${VAULT_SECRET_PATH:?}"
TOKEN_FILE=${1:?token file}

# auth/keycloak = JWT auth backend validating Keycloak tokens (see vault/main.tf)
LOGIN=$(jq -n --arg role "$VAULT_ROLE" --rawfile jwt "$TOKEN_FILE" \
    '{role: $role, jwt: ($jwt | rtrimstr("\n"))}' \
  | curl -sS -X POST --data @- "$VAULT_ADDR/v1/auth/keycloak/login")

VAULT_TOKEN=$(echo "$LOGIN" | jq -r '.auth.client_token // empty')
if [ -z "$VAULT_TOKEN" ]; then
  echo "Vault login failed: $(echo "$LOGIN" | jq -c '.errors // .')" >&2
  exit 1
fi
echo "Logged in to Vault as $(echo "$LOGIN" | jq -r '.auth.metadata | to_entries | map("\(.key)=\(.value)") | join(", ")')" >&2

SECRET=$(curl -sS -H "X-Vault-Token: $VAULT_TOKEN" "$VAULT_ADDR/v1/$VAULT_SECRET_PATH")
if ! echo "$SECRET" | jq -e '.data.data' >/dev/null; then
  echo "Reading $VAULT_SECRET_PATH failed: $(echo "$SECRET" | jq -c '.errors // .')" >&2
  exit 1
fi

# Demo only: print the secret. Real jobs would export it instead.
echo "$SECRET" | jq '.data.data'
