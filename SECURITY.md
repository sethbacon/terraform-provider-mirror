# Security Policy

## Reporting a vulnerability

Report suspected vulnerabilities through GitHub's private vulnerability
reporting on this repository (**Security → Report a vulnerability**). Please do
not open a public issue for an unfixed vulnerability.

Include the action version or commit SHA, the inputs in use, and what an
attacker would gain. You should get an acknowledgement within a few days.

## Supported versions

Fixes land on `main` and ship in the next `v1.x` tag. The floating `v1` alias is
moved by the release workflow to the newest `v1.x`, so a consumer pinned to `v1`
picks the fix up on its next run. Older majors are not maintained.

| Version | Supported |
| ------- | --------- |
| `v1.x`  | yes       |

## Threat model

Worth stating plainly, because it decides which inputs are safe to wire from
where.

**Every input to this action is assumed to be author-controlled.** The action
writes a Terraform/OpenTofu CLI configuration file and exports
`TF_CLI_CONFIG_FILE`, which together decide **where `terraform init` downloads
provider plugins from** — and those plugins are executed during `plan` and
`apply`. Anyone who controls `mirror-url`, the include/exclude patterns, or
`config-path` therefore influences code execution in the consumer's job.

Consequently:

- **Do not wire any input from untrusted event data.** `github.event.*`, a pull
  request title or body, a branch or tag name, or a matrix value derived from
  any of those are all attacker-controlled on a fork pull request. Use literals
  or repository/organisation variables and secrets.
- `mirror-url` is validated as an HTTPS URL with a real authority, and values
  that would break out of the generated HCL are rejected rather than escaped.
- `config-path` is written verbatim and **overwrites** whatever is there. It is
  rejected if it contains a newline or carriage return, because that would forge
  additional `$GITHUB_ENV` entries for every later step in the job.
- Credentials embedded in `mirror-url` (`https://user:token@host/...`, or a
  pre-signed query string) are masked before anything is printed, but a
  composite action cannot mask them retroactively — prefer a mirror that does
  not require an inline credential.

## Pinning

For supply-chain-sensitive workflows, pin this action to a full commit SHA
rather than to `@v1`. See the README's "Pinning this action" section — `@v1` is
a mutable pointer that this repository's maintainers can move.

## Shared CI workflows

Part of this repository's CI is **defined in another repository** — [`4cloudguru/shared-workflows`](https://github.com/4cloudguru/shared-workflows) — and called from `.github/workflows/`. That is a real supply-chain relationship, and it is recorded here so an audit of this repository does not stop at this repository's own tree.

**What runs, and where it is pinned.** Each caller in `.github/workflows/` names the shared workflow on its `uses:` line, pinned to a full 40-hex commit SHA with a trailing comment naming the release that SHA is. The tag is a label; the SHA is what runs. An unlabelled SHA is rejected by the workflow-hardening gate, because a bare 40-hex ref cannot be reviewed or updated deliberately.

**Why the pins have to agree across repositories.** A shared definition drifts differently from a duplicated file: every repository looks like it is using "the shared one" while sitting on different commits, which is *harder* to see than divergent files, not easier. A signature in `security-orchestration` (`shared-workflow-pin-parity`) reports **disagreement** between callers of the same shared workflow — it reports disagreement rather than staleness, because a repository deliberately held back is a decision while N repositories disagreeing without anyone deciding is drift.

**What the shared repository is itself protected by.** Its `main` requires its own zizmor and actionlint checks with `enforce_admins` enabled, restricts which third-party actions may run to an explicit allowlist, issues a read-only default `GITHUB_TOKEN`, and runs the workflow-hardening gate against itself.

**What this repository still controls.** Triggers, concurrency, and the secrets it passes. Secrets are passed **by name** — never `secrets: inherit`, which would forward every secret in this repository to a workflow owned by someone else. Any `vars.*` a shared workflow reads resolve against **this** repository, so credentials and their installation scope do not move.
