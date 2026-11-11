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

resource "vault_policy" "ci_example_read" {
  name   = "ci-example-read"
  policy = <<-EOT
    path "ci/data/example" {
      capabilities = ["read"]
    }
  EOT
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

  token_policies = [vault_policy.ci_example_read.name]
  token_ttl      = 900
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
