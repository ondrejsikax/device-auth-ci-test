#!/bin/sh
# Log in to Vault with the approved Keycloak Access Token and read a secret.
# Usage: ci-read-vault-secret.sh <token-file>
set -eu

: "${VAULT_ADDR:?}" "${VAULT_ROLE:?}" "${VAULT_SECRET_PATH:?}"
TOKEN_FILE=${1:?token file}

# auth/keycloak = JWT auth backend validating Keycloak tokens (see vault/main.tf)
LOGIN=$(vault write -format=json auth/keycloak/login \
  role="$VAULT_ROLE" jwt="$(cat "$TOKEN_FILE")")
VAULT_TOKEN=$(echo "$LOGIN" | jq -r .auth.client_token)
export VAULT_TOKEN

# Who we are in Vault and which policies we got (from Keycloak groups).
# Taken from the login response: the token has no "default" policy,
# so it can't call token lookup-self.
echo "$LOGIN" | jq '.auth | {metadata, policies, identity_policies}'

# Demo only: print the secret. Real jobs would export it instead.
vault kv get "$VAULT_SECRET_PATH"
