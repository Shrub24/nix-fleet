variable "owner" {
  description = "The user or organisation that owns the repositories."
  type        = string
}

variable "repositories" {
  description = <<-EOT
    The CI surface of each repository, keyed by repository name. This provisions
    configuration the fleet's workflows read; it does not manage the repositories
    themselves.

    build:      the repository calls the reusable build and holds the builder key.
    lifecycle:  the repository takes the update lifecycle: the automation
                environment, the App key, the variables and the labels.
    ruleset:    "disabled" until one candidate has validated and promoted by hand,
                then "active". Never require `update-accepted`.
  EOT
  type = map(object({
    build          = optional(bool, false)
    lifecycle      = optional(bool, false)
    default_branch = optional(string, "main")

    # Lifecycle variables. Null leaves the workflow default in force.
    promotion_policy = optional(string)
    pin_name         = optional(string)
    targets          = optional(string)
    systems          = optional(string)
    runner_system    = optional(string)
    profile          = optional(string)
    update_authors   = optional(string)

    ruleset = optional(string, "disabled")
  }))

  validation {
    condition     = alltrue([for r in var.repositories : contains(["disabled", "evaluate", "active"], r.ruleset)])
    error_message = "repositories: ruleset must be one of disabled, evaluate, active."
  }

  validation {
    condition     = alltrue([for r in var.repositories : r.promotion_policy == null || contains(["auto", "label"], r.promotion_policy)])
    error_message = "repositories: promotion_policy must be auto or label."
  }

  validation {
    condition     = alltrue([for r in var.repositories : r.ruleset == "disabled" || r.lifecycle])
    error_message = "repositories: a ruleset requires the update lifecycle, since it requires the status the lifecycle posts."
  }
}

variable "app_id" {
  description = "Numeric ID of the automation GitHub App. Not a secret."
  type        = string
}

variable "app_slug" {
  description = "Slug of the automation GitHub App."
  type        = string
}

variable "app_private_key" {
  description = "PEM private key of the automation App. Distributed to every lifecycle repository's `automation` environment. Null leaves the stored secrets untouched."
  type        = string
  sensitive   = true
  default     = null
}

variable "builder_ssh_key" {
  description = "Private key the build uses to reach the builders (FLEET_BUILDER_SSH_KEY). Null leaves the stored secrets untouched."
  type        = string
  sensitive   = true
  default     = null
}
