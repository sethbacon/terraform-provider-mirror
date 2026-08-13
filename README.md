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
| `allow-direct-fallback` | `false` | permit falling back to the origin registry |
| `direct-include-patterns` | `""` | newline-separated source patterns that bypass the mirror (takes precedence over exclude) |
| `direct-exclude-patterns` | `""` | newline-separated source patterns forced through the mirror |
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
- uses: sethbacon/terraform-provider-mirror@<full-40-char-sha> # v1.0.0
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
