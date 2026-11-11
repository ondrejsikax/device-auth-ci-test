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
