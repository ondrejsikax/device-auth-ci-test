# Keycloak config for the GitLab CI + device code demo.
# Copy into the Keycloak Terraform repo (provider: keycloak/keycloak).
#
# Federated client authentication (Keycloak 26.5+) is newer than the provider's
# typed fields, so it is set via raw attributes in extra_config.
# TODO: verify the attribute names below against your Keycloak version
#       (export the client/IdP JSON after configuring one in the UI and compare).

locals {
  gitlab_url     = "https://gitlab.sikalabs.com"
  gitlab_project = "examples/2026-11-11-wip-example-of-gitlab-ci-with-device-code-keycloak-auth"
  gitlab_ref     = "master"
}

data "keycloak_realm" "training" {
  realm = "training"
}

# GitLab as an IdP, used only to validate GitLab CI id_tokens (client assertions)
resource "keycloak_oidc_identity_provider" "gitlab" {
  realm              = data.keycloak_realm.training.id
  alias              = "gitlab"
  display_name       = "GitLab CI"
  provider_id        = "oidc"
  issuer             = local.gitlab_url
  authorization_url  = "https://gitlab.sikalabs.com/oauth/authorize"
  token_url          = "https://gitlab.sikalabs.com/oauth/token"
  jwks_url           = "https://gitlab.sikalabs.com/oauth/discovery/keys"
  validate_signature = true
  hide_on_login_page = true
  client_id          = "unused"
  client_secret      = "unused"
  sync_mode          = "IMPORT"

  extra_config = {
    "supportsClientAssertions" = "true"
    # The job sends the same KC_JWT on the device request and every poll
    "supportsClientAssertionReuse" = "true"
  }
}

# Client the CI job uses; no secret, authenticates with the GitLab id_token
resource "keycloak_openid_client" "gitlab_ci_project_827" {
  realm_id  = data.keycloak_realm.training.id
  client_id = "gitlab_ci_project_827"
  name      = "GitLab CI (${local.gitlab_project})"

  access_type                               = "CONFIDENTIAL"
  client_authenticator_type                 = "federated-jwt"
  standard_flow_enabled                     = false
  direct_access_grants_enabled              = false
  service_accounts_enabled                  = false
  oauth2_device_authorization_grant_enabled = true
  oauth2_device_code_lifespan               = 300

  extra_config = {
    "jwt.credential.issuer" = keycloak_oidc_identity_provider.gitlab.alias
    # Only jobs from this project and branch can authenticate as this client
    "jwt.credential.sub" = "project_path:${local.gitlab_project}:ref_type:branch:ref:${local.gitlab_ref}"
  }
}

# Realms created before federated client auth existed don't have the
# "Signed JWT - Federated" step in their client authentication flow, and the
# built-in "clients" flow can't be modified. So we create our own client flow
# (the 4 default steps + federated-jwt) and bind it to the realm.
# Without it every federated client fails with client_not_found / invalid_client.
resource "keycloak_authentication_flow" "clients_with_federated" {
  realm_id    = data.keycloak_realm.training.id
  alias       = "clients-with-federated"
  provider_id = "client-flow"
}

locals {
  client_authenticators = [
    "client-secret",
    "client-jwt",
    "client-secret-jwt",
    "client-x509",
    "federated-jwt",
  ]
}

resource "keycloak_authentication_execution" "clients_with_federated" {
  for_each = { for i, a in local.client_authenticators : a => i }

  realm_id          = data.keycloak_realm.training.id
  parent_flow_alias = keycloak_authentication_flow.clients_with_federated.alias
  authenticator     = each.key
  requirement       = "ALTERNATIVE"
  priority          = (each.value + 1) * 10
}

resource "keycloak_authentication_bindings" "training" {
  realm_id                   = data.keycloak_realm.training.id
  client_authentication_flow = keycloak_authentication_flow.clients_with_federated.alias

  depends_on = [keycloak_authentication_execution.clients_with_federated]
}

# aud=vault in the Access Token, required by the Vault JWT role (vault/main.tf)
resource "keycloak_openid_audience_protocol_mapper" "gitlab_ci_project_827_vault" {
  realm_id                 = data.keycloak_realm.training.id
  client_id                = keycloak_openid_client.gitlab_ci_project_827.id
  name                     = "vault-audience"
  included_custom_audience = "vault"
  add_to_access_token      = true
  add_to_id_token          = false
}

# --- Vault SSO (client "vault"): groups claim for vault-admins / vault-viewers ---

data "keycloak_openid_client" "vault" {
  realm_id  = data.keycloak_realm.training.id
  client_id = "vault"
}

resource "keycloak_group" "vault_admins" {
  realm_id = data.keycloak_realm.training.id
  name     = "vault-admins"
}

resource "keycloak_group" "vault_viewers" {
  realm_id = data.keycloak_realm.training.id
  name     = "vault-viewers"
}

# "groups": ["vault-admins", ...] in the ID token (full_path = false, no leading "/")
resource "keycloak_openid_group_membership_protocol_mapper" "vault_groups" {
  realm_id            = data.keycloak_realm.training.id
  client_id           = data.keycloak_openid_client.vault.id
  name                = "groups"
  claim_name          = "groups"
  full_path           = false
  add_to_id_token     = true
  add_to_access_token = true
  add_to_userinfo     = true
}
