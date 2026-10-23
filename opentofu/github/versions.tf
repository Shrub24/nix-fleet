terraform {
  required_version = ">= 1.10"

  required_providers {
    github = {
      source  = "integrations/github"
      version = "~> 6.6"
    }
  }

  # The remote state backend is chosen at `tofu init -backend-config=backend.hcl`
  # (see backend.hcl.example); the state holds the secrets below, so it is encrypted
  # through TF_ENCRYPTION and never committed.
  backend "s3" {}

}

# Authentication is the operator's own token (GITHUB_TOKEN, e.g. `gh auth token`).
# No credential for this provider is stored anywhere.
provider "github" {
  owner = var.owner
}
