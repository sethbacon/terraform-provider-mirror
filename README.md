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
| `config-path` | `$RUNNER_TEMP/.terraformrc` | where to write the config — **any existing file there is overwritten without warning** |
| `log-config` | `false` | print the generated configuration to the step log |

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

Only HTTPS mirror URLs are accepted. The scheme is matched case-insensitively,
per RFC 3986.

## What this action does to your job

Both are deliberate, and both are things to know before composing this action
with other steps:

- **The exports are job-wide and cannot be undone.** `TF_CLI_CONFIG_FILE` (and
  `TOFU_CLI_CONFIG_FILE` for `binary: tofu`) are written to `$GITHUB_ENV`, so
  every *later* step in the job installs providers from the mirror — including
  steps that have nothing to do with Terraform. A composite action has no `post:`
  hook, so there is no way to restore the previous value. If one was already set,
  the action now says so with a `::warning::` before replacing it.
- **The config file is overwritten and then stays.** Any existing file at
  `config-path` is replaced without a backup; if another step wrote registry
  credentials there earlier in the job, they are gone. The file is written with
  mode `600` and left in place for the rest of the job — do not upload or cache
  `$RUNNER_TEMP` (or the `config-file-path` directory) as a build artifact.

## Security notes

**HTTPS is not content trust.** A network mirror is exactly as trustworthy as
whoever operates it and whoever holds its TLS certificate. HashiCorp's own
documentation is blunt about this: *"Don't configure `network_mirror` URLs that
you do not trust… a network mirror with a TLS certificate can potentially serve
modified copies of upstream providers with malicious content."* The
[provider network mirror protocol](https://developer.hashicorp.com/terraform/internals/provider-network-mirror-protocol)
has **no signature verification** — integrity rests on an optional, *mirror-supplied*
`hashes` property, and if the mirror omits it, *"Terraform will install the
indicated archive with no verification."* Your `.terraform.lock.hcl` hashes
remain the primary integrity control; commit them and review changes to them.

**`mirror-url` must not carry a credential.** The action rejects embedded
userinfo (`https://user:pass@host/`) and query strings outright rather than
escaping them, because the value is written into an HCL string. Give the mirror's
credentials to Terraform through a `credentials` block or a `.netrc` file
instead. Anything credential-shaped that does reach the action is passed through
`::add-mask::` before it is validated, so a rejected URL does not leak its secret
into the log — but a composite action cannot call `core.setSecret`, so masking
here is best-effort by construction. This is the one place `hashicorp/setup-terraform`,
being a JavaScript action, can do something this action cannot.

The generated configuration is **not** printed to the log by default. Set
`log-config: "true"` if you want it, bearing in mind that build logs are
world-readable on a public repository.

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
