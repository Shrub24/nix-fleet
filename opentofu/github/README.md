# GitHub repository provisioning

OpenTofu for the CI surface the fleet's workflows read: the `automation`
environment and its default-branch policy, the App key, builder key, repository
variables, labels and the `update-candidate` ruleset. It does not create
repositories, register or install the App, or touch Tailscale and niks3 claims.

## What stays manual

- Creating the organisation, registering the App and generating its private key
  (web UI; there is no API).
- Installing the App on each repository.
- Producing the private key. This configuration only distributes it.

## Use

```sh
cp repositories.auto.tfvars.example repositories.auto.tfvars   # edit
cp backend.hcl.example backend.hcl                              # edit
export GITHUB_TOKEN=$(gh auth token)                            # needs repo + admin:org
export TF_ENCRYPTION=...                                        # state encryption, see below
tofu init -backend-config=backend.hcl
tofu plan  -var-file=secrets.auto.tfvars
```

Secrets enter as `app_private_key` and `builder_ssh_key`, from an ignored
`secrets.auto.tfvars` or `TF_VAR_*`. Leave one null and its stored secrets are
left alone, so rotating one key never needs the other.

## State holds the secrets

The provider writes secret values into state. Keep state in a private bucket,
encrypt it with OpenTofu's native state encryption (`TF_ENCRYPTION`), and never
commit it or a `*.tfvars` file. Rotation is one `tofu apply`.

## Ruleset order

Start with `ruleset = "disabled"`. Switch to `"active"` only after one candidate
has validated and promoted by hand: the ruleset requires `update-candidate` on
every push to the default branch, including the operator's own. `update-accepted`
is never a required context, because removing the label posts it as a failure.
