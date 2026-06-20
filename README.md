# provider-mirror

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
