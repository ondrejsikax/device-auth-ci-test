#!/bin/sh
# Log in to Vault with the approved Keycloak Access Token and read a secret.
# Usage: ci-read-vault-secret.sh <token-file>
set -eu

: "${VAULT_ADDR:?}" "${VAULT_ROLE:?}" "${VAULT_SECRET_PATH:?}"
TOKEN_FILE=${1:?token file}

# auth/keycloak = JWT auth backend validating Keycloak tokens (see vault/main.tf)
VAULT_TOKEN=$(vault write -field=token auth/keycloak/login \
  role="$VAULT_ROLE" jwt="$(cat "$TOKEN_FILE")")
export VAULT_TOKEN

# Who we are in Vault and which policies we got (from Keycloak groups)
vault token lookup -format=json | jq '.data | {display_name, policies, identity_policies}'

# Demo only: print the secret. Real jobs would export it instead.
vault kv get "$VAULT_SECRET_PATH"
