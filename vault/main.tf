# Vault config for the demo: Keycloak JWT auth for the approved CI token,
# an example secret, and an admin user.
#
# Usage:
#   export VAULT_TOKEN=root
#   terraform init && terraform apply

terraform {
  required_providers {
    vault = {
      source = "hashicorp/vault"
    }
  }
}

provider "vault" {
  address = "https://vault-dev.panda.k8s.sl.zone"
  token   = "root"
}

locals {
  keycloak_issuer    = "https://sso.sikalabs.com/realms/training"
  keycloak_client_id = "gitlab_ci_project_827"
}

# --- Example secret ---

resource "vault_mount" "ci" {
  path = "ci"
  type = "kv"
  options = {
    version = "2"
  }
}

resource "vault_kv_secret_v2" "example" {
  mount = vault_mount.ci.path
  name  = "example"
  data_json = jsonencode({
    username = "demo"
    password = "hello-from-vault"
  })
}

# --- Keycloak JWT auth: accepts the access token from oidc-device-login-federated ---

resource "vault_jwt_auth_backend" "keycloak" {
  path               = "keycloak"
  type               = "jwt"
  oidc_discovery_url = local.keycloak_issuer
  bound_issuer       = local.keycloak_issuer
}

resource "vault_jwt_auth_backend_role" "gitlab_ci_project_827" {
  backend   = vault_jwt_auth_backend.keycloak.path
  role_name = "gitlab-ci-project-827"
  role_type = "jwt"

  # Approving user becomes the Vault entity (visible in audit log)
  user_claim      = "preferred_username"
  bound_audiences = ["vault"]
  bound_claims = {
    # Only tokens issued to the CI client (job + user approval)
    azp = local.keycloak_client_id
  }

  # Policies come only from the approver's Keycloak groups (vault-admins,
  # vault-viewers), same as SSO login. Approvers in neither group get nothing.
  groups_claim            = "groups"
  token_policies          = []
  token_no_default_policy = true
  token_ttl               = 900
}

# --- Admin user (admin / admin), dev only ---

resource "vault_auth_backend" "userpass" {
  type = "userpass"
}

resource "vault_policy" "admin" {
  name   = "admin"
  policy = <<-EOT
    path "*" {
      capabilities = ["create", "read", "update", "patch", "delete", "list", "sudo"]
    }
  EOT
}

resource "vault_generic_endpoint" "user_admin" {
  path                 = "auth/${vault_auth_backend.userpass.path}/users/admin"
  ignore_absent_fields = true
  data_json = jsonencode({
    password       = "admin"
    token_policies = [vault_policy.admin.name]
  })
}

# --- SSO login (UI + CLI) via Keycloak, client "vault" ---

resource "vault_jwt_auth_backend" "oidc" {
  path               = "oidc"
  type               = "oidc"
  oidc_discovery_url = local.keycloak_issuer
  bound_issuer       = local.keycloak_issuer
  oidc_client_id     = "vault"
  oidc_client_secret = "vault"
  default_role       = "default"

  tune {
    # Show "OIDC" in the UI login method list
    listing_visibility = "unauth"
  }
}

resource "vault_jwt_auth_backend_role" "oidc_default" {
  backend   = vault_jwt_auth_backend.oidc.path
  role_name = "default"
  role_type = "oidc"

  user_claim      = "preferred_username"
  bound_audiences = ["vault"]
  oidc_scopes     = ["openid", "profile", "email"]
  allowed_redirect_uris = [
    "https://vault-dev.panda.k8s.sl.zone/ui/vault/auth/oidc/oidc/callback",
    # vault login -method=oidc
    "http://localhost:8250/oidc/callback",
  ]

  # Policies come only from Keycloak groups (vault-admins, vault-viewers),
  # see external groups below. Users in neither group get nothing.
  groups_claim            = "groups"
  token_policies          = []
  token_no_default_policy = true
  token_ttl               = 3600
}

# Read-only access to all secrets (KV v2 mounts ci/ and secret/)
resource "vault_policy" "secrets_read" {
  name   = "secrets-read"
  policy = <<-EOT
    path "ci/data/*" {
      capabilities = ["read"]
    }
    path "ci/metadata/*" {
      capabilities = ["read", "list"]
    }
    path "secret/data/*" {
      capabilities = ["read"]
    }
    path "secret/metadata/*" {
      capabilities = ["read", "list"]
    }
    # Let the UI list secrets engines
    path "sys/mounts" {
      capabilities = ["read"]
    }
  EOT
}

# Keycloak group -> Vault external group -> policy
locals {
  oidc_groups = {
    "vault-admins"  = vault_policy.admin.name
    "vault-viewers" = vault_policy.secrets_read.name
  }
}

resource "vault_identity_group" "oidc" {
  for_each = local.oidc_groups

  name     = each.key
  type     = "external"
  policies = [each.value]
}

# Each group needs an alias per auth mount: SSO (oidc) and CI (keycloak)
locals {
  oidc_group_mounts = {
    oidc     = vault_jwt_auth_backend.oidc.accessor
    keycloak = vault_jwt_auth_backend.keycloak.accessor
  }
  oidc_group_aliases = {
    for pair in setproduct(keys(local.oidc_groups), keys(local.oidc_group_mounts)) :
    "${pair[0]}/${pair[1]}" => { group = pair[0], mount = pair[1] }
  }
}

resource "vault_identity_group_alias" "oidc" {
  for_each = local.oidc_group_aliases

  # Must equal the group name in the token's "groups" claim
  name           = each.value.group
  mount_accessor = local.oidc_group_mounts[each.value.mount]
  canonical_id   = vault_identity_group.oidc[each.value.group].id
}

# Existing SSO aliases were keyed by group name only
moved {
  from = vault_identity_group_alias.oidc["vault-admins"]
  to   = vault_identity_group_alias.oidc["vault-admins/oidc"]
}

moved {
  from = vault_identity_group_alias.oidc["vault-viewers"]
  to   = vault_identity_group_alias.oidc["vault-viewers/oidc"]
}
