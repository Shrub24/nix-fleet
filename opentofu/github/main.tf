locals {
  lifecycle = { for name, r in var.repositories : name => r if r.lifecycle }
  build     = { for name, r in var.repositories : name => r if r.build }
  ruleset   = { for name, r in var.repositories : name => r if r.ruleset != "disabled" }

  # Variables the workflows read. Null is omitted so the workflow default applies.
  variables = merge([
    for name, r in local.lifecycle : {
      for key, value in {
        AUTOMATION_APP_ID         = var.app_id
        AUTOMATION_APP_SLUG       = var.app_slug
        PROMOTION_POLICY          = r.promotion_policy
        CACHE_PIN_NAME            = r.pin_name
        CANDIDATE_TARGETS         = r.targets
        CANDIDATE_SYSTEMS         = r.systems
        CANDIDATE_RUNNER_SYSTEM   = r.runner_system
        CANDIDATE_PROFILE         = r.profile
        AUTOMATION_UPDATE_AUTHORS = r.update_authors
      } : "${name}/${key}" => { repository = name, name = key, value = value } if value != null
    }
  ]...)

  # `accept-update` exists only for the label policy; the producer's pull-request
  # step fails with a 404 when `automated` or `dependencies` is missing.
  labels = merge([
    for name, r in local.lifecycle : {
      for label in concat(["automated", "dependencies"], r.promotion_policy == "label" ? ["accept-update"] : []) :
      "${name}/${label}" => { repository = name, name = label }
    }
  ]...)
}

# The App key is readable only by jobs that name this environment, and only from
# the default branch, which is what keeps it away from pull-request runs.
resource "github_repository_environment" "automation" {
  for_each    = local.lifecycle
  repository  = each.key
  environment = "automation"

  deployment_branch_policy {
    protected_branches     = false
    custom_branch_policies = true
  }
}

resource "github_repository_environment_deployment_policy" "default_branch" {
  for_each       = local.lifecycle
  repository     = each.key
  environment    = github_repository_environment.automation[each.key].environment
  branch_pattern = each.value.default_branch
}

resource "github_actions_environment_secret" "app_key" {
  for_each    = nonsensitive(var.app_private_key != null) ? local.lifecycle : {}
  repository  = each.key
  environment = github_repository_environment.automation[each.key].environment
  secret_name = "AUTOMATION_APP_PRIVATE_KEY"
  value       = var.app_private_key
}

resource "github_actions_secret" "builder_key" {
  for_each    = nonsensitive(var.builder_ssh_key != null) ? local.build : {}
  repository  = each.key
  secret_name = "FLEET_BUILDER_SSH_KEY"
  value       = var.builder_ssh_key
}

resource "github_actions_variable" "this" {
  for_each      = local.variables
  repository    = each.value.repository
  variable_name = each.value.name
  value         = each.value.value
}

resource "github_issue_label" "this" {
  for_each   = local.labels
  repository = each.value.repository
  name       = each.value.name
  color      = "ededed"
}

# Requires the status the lifecycle posts, pinned to the App that posts it so
# another identity cannot satisfy it. There is no bypass and no pull-request rule:
# promotion is a fast-forward push of the validated commit.
resource "github_repository_ruleset" "update_candidate" {
  for_each    = local.ruleset
  repository  = each.key
  name        = "update-candidate"
  target      = "branch"
  enforcement = each.value.ruleset

  conditions {
    ref_name {
      include = ["~DEFAULT_BRANCH"]
      exclude = []
    }
  }

  rules {
    required_status_checks {
      required_check {
        context        = "update-candidate"
        integration_id = tonumber(var.app_id)
      }
    }
  }
}
