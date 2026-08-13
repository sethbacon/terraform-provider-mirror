# provider-mirror

[![GitHub release](https://img.shields.io/github/v/release/sethbacon/terraform-provider-mirror?logo=github&label=Marketplace&color=2ea44f)](https://github.com/marketplace/actions/terraform-provider-mirror)
[![License: Apache 2.0](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](LICENSE)

Configure Terraform or OpenTofu to pull providers from a **network mirror**
instead of the public registry. Writes a CLI config file and exports
`TF_CLI_CONFIG_FILE` (and `TOFU_CLI_CONFIG_FILE` for OpenTofu) for subsequent
steps.

## Inputs

| Input | Default | Notes |
|-------|---------|-------|
| `mirror-url` | — (required) | HTTPS base URL of the network mirror |
| `binary` | `terraform` | `terraform` or `tofu` (controls which CLI-config env vars are exported) |
| `allow-direct-fallback` | `false` | add a `direct` installation method alongside the mirror — **not** a conditional fallback, see below |
| `direct-include-patterns` | `""` | newline-separated source patterns the `direct` method is limited to |
| `direct-exclude-patterns` | `""` | newline-separated source patterns the `direct` method must not handle |
| `config-path` | `$RUNNER_TEMP/.terraformrc` | where to write the config |

## Outputs

| Output | Notes |
|--------|-------|
| `config-file-path` | absolute path of the written CLI config |

## Example

```yaml
- uses: sethbacon/terraform-provider-mirror@v1
  with:
    binary: tofu
    mirror-url: https://registry.internal.example.com/providers
    allow-direct-fallback: "true"
    direct-include-patterns: |
      registry.terraform.io/hashicorp/*
- run: tofu init   # uses the mirror via TOFU_CLI_CONFIG_FILE
```

Only HTTPS mirror URLs are accepted.

## Pinning this action

The example above uses `@v1` for readability. **`v1` is a mutable tag** — this
repository's maintainers move it to each new `v1.x`, so what your workflow
executes changes without any diff on your side. That is a convenience, and it is
a trust decision you are making about this repository. It matters more than
usual here: this action writes the CLI configuration that decides where
`terraform init` fetches provider plugins from, and those plugins are executed
during `plan` and `apply`.

For supply-chain-sensitive workflows, pin the full commit SHA instead:

```yaml
- uses: sethbacon/terraform-provider-mirror@02563b8dd312f42c5f5b539449ef1b071a766d37 # v1.0.0
  with:
    mirror-url: https://registry.internal.example.com/providers
```

The trailing comment is what makes the pin maintainable — Dependabot reads it,
and so does the next human. The tradeoff is the mirror image of `@v1`: a SHA pin
never changes under you, and it never picks up a fix either, so it needs
updating deliberately.

Releases are cut by [`release.yml`](.github/workflows/release.yml), which
re-runs the manifest check and the action's test suite against the tagged tree,
refuses a tag that is not reachable from `main`, emits a
[build-provenance attestation](https://docs.github.com/actions/security-guides/using-artifact-attestations)
over `action.yml`, and only then moves the `v1` alias. You can verify a release
with:

```bash
gh attestation verify --owner sethbacon --repo terraform-provider-mirror action.yml
```
## How Terraform actually chooses an installation method

This matters because the obvious reading of "fallback" is wrong, and the
difference decides whether your providers come from the mirror at all.

Terraform does **not** try the mirror first and fall back when it misses. It
[queries *every* installation method whose `include`/`exclude` patterns match a
provider, and installs the newest version any of them
offers](https://developer.hashicorp.com/terraform/cli/config/config-file#provider-installation).

Two consequences:

- **`allow-direct-fallback: "true"` with both pattern inputs empty re-enables
  direct installation for every provider, not just missing ones.** A bare
  `direct {}` block matches everything, and the generated `network_mirror` block
  has no patterns either, so whenever the public registry has a newer version
  than your mirror, Terraform takes the registry's — EVERY provider may be
  installed from the origin registry, not just ones the mirror is missing. If your reason for running a
  mirror is pinning, auditing or air-gap rehearsal, that silently defeats it.
  Scope the `direct` method with `direct-include-patterns` whenever you enable
  it.
- **When both `include` and `exclude` are set on one method, `exclude` wins.**
  This action never emits both on the same block — `direct-include-patterns`
  takes priority and `direct-exclude-patterns` is used only when include is
  empty — so the generated config is unambiguous. Earlier revisions of this
  README described include as "taking precedence over exclude" as though it were
  a Terraform rule; it is not, it is a property of what this action generates.
