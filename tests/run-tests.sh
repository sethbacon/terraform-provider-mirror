#!/usr/bin/env bash
#
# Behavioural tests for the shell implementation inside action.yml.
#
# The step script is extracted from action.yml and executed for real against a
# stubbed runner ($RUNNER_TEMP, $GITHUB_WORKSPACE, $GITHUB_ENV, $GITHUB_OUTPUT
# are directories and files under a scratch dir). Every assertion is an observed
# exit status, an observed line of output, or the observed bytes of the file the
# action wrote — for the injection cases the exit status alone proves nothing,
# so those cases assert that no second network_mirror block and no second
# $GITHUB_ENV entry exist.
#
# The cases are grouped per defect class, and the row names carry the class name
# so tests/mutations.sh can require that disabling one guard reddens that
# guard's rows and no others.
#
# Usage:  tests/run-tests.sh
#   ACTION_YML=path  run against a copy of action.yml (used by the mutation run)
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ACTION_YML="${ACTION_YML:-$REPO_ROOT/action.yml}"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

PASS=0
FAIL=0
SEQ=0

note() { printf '\n=== %s\n' "$1"; }
pass() { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n     %s\n' "$1" "$2"; }
tail3() { printf '%s' "$OUT" | tail -3 | tr '\n' '|'; }

# ---------------------------------------------------------------- extraction --
python3 - "$ACTION_YML" >"$T/mirror.sh" <<'PY'
import sys, yaml
doc = yaml.safe_load(open(sys.argv[1]))
step = [s for s in doc["runs"]["steps"] if s.get("id") == "mirror"][0]
sys.stdout.write(step["run"])
PY

# The declared defaults are what a consumer gets from `- uses: ...@v1` with no
# `with:` block, so every case is driven from them rather than from values
# written out again here.
python3 - "$ACTION_YML" >"$T/defaults.env" <<'PY'
import shlex, sys, yaml
i = yaml.safe_load(open(sys.argv[1]))["inputs"]
for var, name in (
    ("DEF_BINARY", "binary"),
    ("DEF_ALLOW_DIRECT", "allow-direct-fallback"),
    ("DEF_INCLUDE", "direct-include-patterns"),
    ("DEF_EXCLUDE", "direct-exclude-patterns"),
    ("DEF_CONFIG_PATH", "config-path"),
    ("DEF_LOG_CONFIG", "log-config"),
):
    print("%s=%s" % (var, shlex.quote(str(i[name]["default"]))))
PY
# shellcheck disable=SC1091
. "$T/defaults.env"

GOOD_URL="https://mirror.example.com/tf/"

# ------------------------------------------------------------------- runner --
STATUS=0
OUT=""
RT=""
LAST=""

new_rt() { # a fresh stubbed runner; call directly when a case needs to set the
           # destination up (an existing file, a symlink, a directory) first.
  RT="$T/run.$((++SEQ))"
  mkdir -p "$RT/tmp" "$RT/ws" "$RT/outside"
  : >"$RT/env"
  : >"$RT/out"
}

run_action() { # run_action [VAR=VAL ...] — later assignments win over the defaults
  if [ -z "$RT" ]; then new_rt; fi
  set +e
  (
    cd "$RT/ws" && env \
      RUNNER_TEMP="$RT/tmp" GITHUB_WORKSPACE="$RT/ws" \
      GITHUB_ENV="$RT/env" GITHUB_OUTPUT="$RT/out" \
      MIRROR_URL="$GOOD_URL" BINARY="$DEF_BINARY" ALLOW_DIRECT="$DEF_ALLOW_DIRECT" \
      INCLUDE_PATTERNS="$DEF_INCLUDE" EXCLUDE_PATTERNS="$DEF_EXCLUDE" \
      CONFIG_PATH_IN="$DEF_CONFIG_PATH" LOG_CONFIG="$DEF_LOG_CONFIG" \
      "$@" bash "$T/mirror.sh"
  ) >"$RT/log" 2>&1
  STATUS=$?
  set -e
  OUT="$(cat "$RT/log")"
  LAST="$RT"
  RT=""
}

CFG() { printf '%s' "$LAST/tmp/.terraformrc"; } # the default destination

# $GITHUB_ENV and $GITHUB_OUTPUT parsed the way the runner parses them: a
# `KEY<<DELIM` block, or a bare `KEY=VALUE` line — which is exactly the forged
# entry the heredoc form exists to make impossible. Prints one KEY per line.
keys_of() { # <file>
  awk '
    state == 1 { if ($0 == delim) { state = 0 }; next }
    /^[A-Za-z_][A-Za-z0-9_.-]*<</ {
      print substr($0, 1, index($0, "<<") - 1)
      delim = substr($0, index($0, "<<") + 2); state = 1; next
    }
    /=/ { print "BARE:" substr($0, 1, index($0, "=") - 1); next }
    $0 != "" { print "MALFORMED:" $0 }
  ' "$1"
}

# Exported below: the assertion helpers invoke this from `bash -c`, which does
# not inherit shell functions unless they are exported.
value_of() { # <file> <key>
  awk -v want="$2" '
    state == 1 { if ($0 == delim) { state = 0; next }; if (hit) { print }; next }
    /^[A-Za-z_][A-Za-z0-9_.-]*<</ {
      hit = (substr($0, 1, index($0, "<<") - 1) == want)
      delim = substr($0, index($0, "<<") + 2); state = 1; next
    }
  ' "$1"
}
export -f value_of

# ---------------------------------------------------------------- assertions --
expect_fail() { # <name> <regex the ::error:: must match>
  local name="$1" re="$2"
  if [ "$STATUS" -eq 0 ]; then
    fail "$name" "expected a non-zero exit, got 0: $(tail3)"
    return
  fi
  if ! printf '%s\n' "$OUT" | grep -Eq "$re"; then
    fail "$name" "expected output to match /$re/: $(tail3)"
    return
  fi
  # A rejected run must not have emitted anything to the caller's job.
  if [ -s "$LAST/env" ] || [ -s "$LAST/out" ]; then
    fail "$name" "a rejected run wrote to GITHUB_ENV/GITHUB_OUTPUT: $(cat "$LAST/env" "$LAST/out" | tr '\n' '|')"
    return
  fi
  pass "$name"
}

expect_ok() { # <name> [regex ...]
  local name="$1" re
  shift
  if [ "$STATUS" -ne 0 ]; then
    fail "$name" "expected success, got exit $STATUS: $(tail3)"
    return
  fi
  for re in "$@"; do
    if ! printf '%s\n' "$OUT" | grep -Eq "$re"; then
      fail "$name" "expected output to match /$re/: $(tail3)"
      return
    fi
  done
  pass "$name"
}

# The point of the HCL cases: not "did it exit non-zero" but "is the file that
# terraform will read still a single mirror pointing where the author said".
expect_config() { # <name> <config file> <expected url> [expected extra line ...]
  local name="$1" f="$2" url="$3" line n
  shift 3
  if [ ! -f "$f" ]; then
    fail "$name" "no configuration was written to $f"
    return
  fi
  n="$(grep -c 'network_mirror' "$f" || true)"
  if [ "$n" != "1" ]; then
    fail "$name" "expected exactly one network_mirror block, found $n: $(tr '\n' '|' <"$f")"
    return
  fi
  n="$(grep -c 'url *=' "$f" || true)"
  if [ "$n" != "1" ]; then
    fail "$name" "expected exactly one url assignment, found $n: $(tr '\n' '|' <"$f")"
    return
  fi
  if ! grep -Fqx "    url = \"$url\"" "$f"; then
    fail "$name" "expected url = \"$url\": $(tr '\n' '|' <"$f")"
    return
  fi
  if grep -q 'http://' "$f"; then
    fail "$name" "a plain-http mirror reached the configuration: $(tr '\n' '|' <"$f")"
    return
  fi
  for line in "$@"; do
    if ! grep -Fqx "$line" "$f"; then
      fail "$name" "expected the line [$line]: $(tr '\n' '|' <"$f")"
      return
    fi
  done
  pass "$name"
}

expect_keys() { # <name> <file> <expected keys, space separated>
  local name="$1" got
  got="$(keys_of "$2" | tr '\n' ' ')"
  got="${got% }"
  if [ "$got" != "$3" ]; then
    fail "$name" "expected keys [$3], got [$got] from $(tr '\n' '|' <"$2")"
    return
  fi
  pass "$name"
}

check() { # <name> <condition description> — run a command, pass/fail on status
  local name="$1"
  shift
  if "$@"; then pass "$name"; else fail "$name" "condition failed: $*"; fi
}

# ============================================================== mirror-url ====
note "mirror-url: required"

run_action MIRROR_URL=""
expect_fail "mirror-url required: an empty value is rejected" '::error::mirror-url is required'

# The character allow-list is what stops a value from closing the HCL string it
# is interpolated into, or from forging a log line. Each of these starts with
# https:// and so passes the prefix check the action used to rely on.
note "mirror-url: character allow-list"

CHARSET_CASES=(
  "closing quote injects a second network_mirror"
  'https://x/" } network_mirror { url = "http://attacker.evil/'

  "trailing backslash escapes the closing quote"
  'https://x/a\'

  "embedded newline forges a workflow command"
  "$(printf 'https://good.example/\n::error::pwned')"

  "embedded newline forges an ::add-mask:: line"
  "$(printf 'https://good.example/\n::add-mask::pwned')"

  "carriage return"
  "$(printf 'https://good.example/\r')"

  "embedded space"
  'https://good.example/ x'

  "embedded tab"
  "$(printf 'https://good.example/\tx')"

  "query string"
  'https://good.example/?token=abc'

  "fragment"
  'https://good.example/#frag'

  "HCL template interpolation"
  'https://good.example/${var}'

  "non-ASCII host"
  'https://good.examplé/'
)

for ((i = 0; i < ${#CHARSET_CASES[@]}; i += 2)); do
  run_action MIRROR_URL="${CHARSET_CASES[i + 1]}"
  expect_fail "mirror-url charset: rejects ${CHARSET_CASES[i]}" \
    '::error::mirror-url contains characters that cannot appear'
  # The forged line must not have reached the log as a command of its own, and
  # nothing may have been written for terraform to read.
  if printf '%s\n' "$OUT" | grep -Eq '^::(error|add-mask)::pwned'; then
    fail "mirror-url charset: ${CHARSET_CASES[i]} cannot forge a log line" "$(tail3)"
  elif [ -e "$(CFG)" ]; then
    fail "mirror-url charset: ${CHARSET_CASES[i]} writes no configuration" "$(cat "$(CFG)")"
  else
    pass "mirror-url charset: ${CHARSET_CASES[i]} forges no log line and writes nothing"
  fi
done

note "mirror-url: scheme and authority"

AUTHORITY_CASES=(
  "http:// scheme" 'http://mirror.example.com/' '::error::mirror-url must start with https://'
  "ftp:// scheme" 'ftp://mirror.example.com/' '::error::mirror-url must start with https://'
  "a bare host with no scheme" 'mirror.example.com/' '::error::mirror-url must start with https://'
  "an empty authority" 'https://' '::error::mirror-url has no host'
  "an empty authority with a path" 'https:///providers' '::error::mirror-url has no host'
  "embedded credentials" 'https://user:t0ken@mirror.example.com/' '::error::mirror-url must not embed credentials'
  "an underscore in the host" 'https://mir_ror.example.com/' '::error::mirror-url has an invalid host'
  "a leading hyphen in the host" 'https://-mirror.example.com/' '::error::mirror-url has an invalid host'
  "a trailing hyphen in the host" 'https://mirror.example-/' '::error::mirror-url has an invalid host'
  "the link-local metadata address is still a host, but a typo like this is not"
  'https://169.254.169.254:/' '::error::mirror-url has an invalid host'
)

for ((i = 0; i < ${#AUTHORITY_CASES[@]}; i += 3)); do
  run_action MIRROR_URL="${AUTHORITY_CASES[i + 1]}"
  expect_fail "mirror-url authority: rejects ${AUTHORITY_CASES[i]}" "${AUTHORITY_CASES[i + 2]}"
done

note "mirror-url: accepted values"

ACCEPT_CASES=(
  "a host with no trailing slash" 'https://mirror.example.com' 'https://mirror.example.com/'
  "a host with one trailing slash" 'https://mirror.example.com/' 'https://mirror.example.com/'
  "a host with several trailing slashes" 'https://mirror.example.com///' 'https://mirror.example.com/'
  "a port and a path" 'https://mirror.example.com:8443/tf/' 'https://mirror.example.com:8443/tf/'
  "an IPv4 literal" 'https://10.0.0.5:8443/m' 'https://10.0.0.5:8443/m/'
  "a percent-encoded path" 'https://mirror.example.com/a%20b/' 'https://mirror.example.com/a%20b/'
)

for ((i = 0; i < ${#ACCEPT_CASES[@]}; i += 3)); do
  run_action MIRROR_URL="${ACCEPT_CASES[i + 1]}"
  expect_ok "mirror-url accepts ${ACCEPT_CASES[i]}" 'Wrote the terraform provider mirror configuration'
  expect_config "mirror-url accepts ${ACCEPT_CASES[i]}: configuration names exactly that mirror" \
    "$(CFG)" "${ACCEPT_CASES[i + 2]}"
done

# ================================================================ log hygiene ==
note "secret hygiene"

SECRET='S3CRET-token-value'
run_action MIRROR_URL="https://svc:$SECRET@mirror.example.com/"
expect_fail "mirror-url mask: credentials in the URL are rejected" \
  '::error::mirror-url must not embed credentials'
if ! printf '%s\n' "$OUT" | grep -Fq "::add-mask::$SECRET"; then
  fail "mirror-url mask: the credential is masked before it is rejected" "$(tail3)"
elif printf '%s\n' "$OUT" | grep -F "$SECRET" | grep -qv '^::add-mask::'; then
  fail "mirror-url mask: the credential appears unmasked in the log" "$(printf '%s\n' "$OUT" | grep -F "$SECRET" | tr '\n' '|')"
else
  pass "mirror-url mask: userinfo is masked and never printed unmasked"
fi

run_action MIRROR_URL="https://mirror.example.com/?token=$SECRET"
expect_fail "mirror-url mask: a query string is rejected" \
  '::error::mirror-url contains characters that cannot appear'
if ! printf '%s\n' "$OUT" | grep -Fq "::add-mask::$SECRET"; then
  fail "mirror-url mask: a token query parameter is masked before it is rejected" "$(tail3)"
elif printf '%s\n' "$OUT" | grep -F "$SECRET" | grep -qv '^::add-mask::'; then
  fail "mirror-url mask: the token appears unmasked in the log" "$(printf '%s\n' "$OUT" | grep -F "$SECRET" | tr '\n' '|')"
else
  pass "mirror-url mask: a token query parameter is masked and never printed unmasked"
fi

run_action
expect_ok "log-config: the configuration is not dumped to the log by default" \
  'Wrote the terraform provider mirror configuration'
check "log-config: the mirror URL is not echoed by default" \
  bash -c '! grep -q network_mirror "$1"' _ "$LAST/log"

run_action LOG_CONFIG=true
expect_ok "log-config: true prints the generated configuration" 'network_mirror'

# ==================================================================== inputs ==
note "input validation"

CHOICE_CASES=(
  "binary: rejects a capitalised value" BINARY Terraform "::error::binary must be one of"
  "binary: rejects an unknown CLI" BINARY opentofu "::error::binary must be one of"
  "allow-direct-fallback: rejects a capitalised boolean" ALLOW_DIRECT True "::error::allow-direct-fallback must be one of"
  "allow-direct-fallback: rejects a numeric boolean" ALLOW_DIRECT 1 "::error::allow-direct-fallback must be one of"
  "log-config: rejects a yes/no boolean" LOG_CONFIG yes "::error::log-config must be one of"
)

for ((i = 0; i < ${#CHOICE_CASES[@]}; i += 4)); do
  run_action "${CHOICE_CASES[i + 1]}=${CHOICE_CASES[i + 2]}"
  expect_fail "${CHOICE_CASES[i]}" "${CHOICE_CASES[i + 3]}"
done

# ================================================================== patterns ==
note "direct include/exclude patterns"

PATTERN_CASES=(
  "a closing quote that injects a second network_mirror"
  'x"] } network_mirror { url = "https://attacker.evil/" } direct { include = ["y'

  "a trailing backslash"
  'a\'

  "an embedded double quote"
  'a"b'

  "a space"
  'foo bar'

  "a semicolon"
  'a;b'

  "a second line that forges a workflow command"
  "$(printf 'registry.terraform.io/hashicorp/*\n::error::pwned')"

  "a brace"
  'reg/ns/{a}'
)

for ((i = 0; i < ${#PATTERN_CASES[@]}; i += 2)); do
  run_action ALLOW_DIRECT=true INCLUDE_PATTERNS="${PATTERN_CASES[i + 1]}"
  expect_fail "patterns: direct-include-patterns rejects ${PATTERN_CASES[i]}" \
    '::error::direct-include-patterns entry .* is not a valid provider source pattern'
  run_action ALLOW_DIRECT=true EXCLUDE_PATTERNS="${PATTERN_CASES[i + 1]}"
  expect_fail "patterns: direct-exclude-patterns rejects ${PATTERN_CASES[i]}" \
    '::error::direct-exclude-patterns entry .* is not a valid provider source pattern'
done

# Patterns are ignored unless allow-direct-fallback is on, but a malformed one
# is still a mistake worth reporting rather than silently dropping.
run_action ALLOW_DIRECT=false INCLUDE_PATTERNS='a"b'
expect_fail "patterns: a malformed pattern is rejected even when it would be unused" \
  '::error::direct-include-patterns entry .* is not a valid provider source pattern'

note "direct block shape"

run_action ALLOW_DIRECT=true INCLUDE_PATTERNS="$(printf 'registry.terraform.io/hashicorp/*\n  reg.example.com/ns/type  \n\n')"
expect_config "patterns: an include list is emitted, trimmed, in one direct block" \
  "$(CFG)" "$GOOD_URL" \
  '  direct {' \
  '    include = ["registry.terraform.io/hashicorp/*", "reg.example.com/ns/type"]'

run_action ALLOW_DIRECT=true EXCLUDE_PATTERNS='registry.terraform.io/hashicorp/*'
expect_config "patterns: an exclude list is emitted when include is empty" \
  "$(CFG)" "$GOOD_URL" \
  '    exclude = ["registry.terraform.io/hashicorp/*"]'

# Terraform gives exclude priority when one method carries both, so the action
# emits only one of them — the README documents which.
run_action ALLOW_DIRECT=true INCLUDE_PATTERNS='a/b/c' EXCLUDE_PATTERNS='d/e/f'
expect_config "patterns: include wins and exclude is not emitted alongside it" \
  "$(CFG)" "$GOOD_URL" '    include = ["a/b/c"]'
check "patterns: the ignored exclude list is absent from the configuration" \
  bash -c '! grep -q exclude "$1"' _ "$(CFG)"

run_action ALLOW_DIRECT=true
expect_config "patterns: no patterns means a bare direct block" "$(CFG)" "$GOOD_URL" '  direct {}'

run_action INCLUDE_PATTERNS='a/b/c'
expect_config "patterns: no direct block at all without allow-direct-fallback" "$(CFG)" "$GOOD_URL"
check "patterns: allow-direct-fallback=false emits no direct block" \
  bash -c '! grep -q direct "$1"' _ "$(CFG)"

# =============================================================== config-path ==
note "config-path"

# The newline payload from the audit: a second $GITHUB_ENV entry exported to
# every later step of the caller's job.
FORGED="$(printf 'rc.terraformrc\nBASH_ENV=payload')"
new_rt
run_action CONFIG_PATH_IN="$RT/tmp/$FORGED"
expect_fail "config-path charset: rejects a newline (the forged \$GITHUB_ENV entry)" \
  '::error::config-path contains characters that are not allowed'

new_rt
run_action CONFIG_PATH_IN="$(printf '%s/tmp/rc.terraformrc\r' "$RT")"
expect_fail "config-path charset: rejects a carriage return" \
  '::error::config-path contains characters that are not allowed'

new_rt
run_action CONFIG_PATH_IN="$RT/tmp/rc.terraformrc\$(id)"
expect_fail "config-path charset: rejects shell metacharacters" \
  '::error::config-path contains characters that are not allowed'

new_rt
run_action CONFIG_PATH_IN="$RT/outside/rc.terraformrc"
expect_fail "config-path containment: rejects a path outside RUNNER_TEMP and GITHUB_WORKSPACE" \
  '::error::config-path .* is outside the directories this action may write to'

new_rt
run_action CONFIG_PATH_IN="$RT/tmp/../outside/rc.terraformrc"
expect_fail "config-path containment: rejects a traversal that leaves RUNNER_TEMP" \
  '::error::config-path .* is outside the directories this action may write to'

new_rt
run_action CONFIG_PATH_IN="$RT/ws/main.tf"
expect_fail "config-path filename: rejects a destination that is not a CLI config file" \
  '::error::config-path must name a CLI configuration file'

new_rt
mkdir -p "$RT/tmp/dir.terraformrc"
run_action CONFIG_PATH_IN="$RT/tmp/dir.terraformrc"
expect_fail "config-path regular file: rejects an existing directory" \
  '::error::config-path .* exists and is not a regular file'

new_rt
: >"$RT/tmp/target.terraformrc"
ln -s "$RT/tmp/target.terraformrc" "$RT/tmp/link.terraformrc"
run_action CONFIG_PATH_IN="$RT/tmp/link.terraformrc"
expect_fail "config-path symlink: refuses to write through a symlink" \
  '::error::config-path .* is a symlink'
check "config-path symlink: the symlink target is left untouched" \
  bash -c '[ ! -s "$1" ]' _ "$LAST/tmp/target.terraformrc"

new_rt
mkdir -p "$RT/ws/sub"
run_action CONFIG_PATH_IN="sub/cli.tfrc"
expect_ok "config-path canonical: a relative path resolves inside the workspace" 'Wrote the terraform'
expect_config "config-path canonical: the relative destination holds the configuration" \
  "$LAST/ws/sub/cli.tfrc" "$GOOD_URL"
check "config-path canonical: the exported path is absolute" \
  bash -c '[ "$(value_of "$1" TF_CLI_CONFIG_FILE)" = "$2" ]' _ "$LAST/env" "$LAST/ws/sub/cli.tfrc"

new_rt
printf 'stale\n' >"$RT/tmp/.terraformrc"
run_action CONFIG_PATH_IN="$RT/tmp/.terraformrc"
expect_ok "config-path: an existing CLI config file is overwritten" 'Wrote the terraform'
expect_config "config-path: the overwritten file holds only the new configuration" "$(CFG)" "$GOOD_URL"

# ====================================================== runner file commands ==
note "runner file commands"

run_action
expect_keys "runner file commands: terraform exports exactly TF_CLI_CONFIG_FILE" \
  "$LAST/env" "TF_CLI_CONFIG_FILE"
expect_keys "runner file commands: exactly one output is set" \
  "$LAST/out" "config-file-path"
check "runner file commands: the exported value is the file that was written" \
  bash -c '[ "$(value_of "$1" TF_CLI_CONFIG_FILE)" = "$2" ] && [ "$(value_of "$3" config-file-path)" = "$2" ]' \
  _ "$LAST/env" "$(CFG)" "$LAST/out"
check "runner file commands: entries use the random-delimiter heredoc form" \
  grep -Eq '^TF_CLI_CONFIG_FILE<<ghadelim_[0-9a-f]{8}' "$LAST/env"

run_action BINARY=tofu
expect_keys "runner file commands: tofu exports both CLI config variables" \
  "$LAST/env" "TF_CLI_CONFIG_FILE TOFU_CLI_CONFIG_FILE"

# The heredoc form is the second line of defence behind the config-path
# character guard: whatever the path guards let through, a newline in the value
# must not become a KEY=VALUE line of its own. tests/mutations.sh removes the
# path guards and requires this row to stay green.
new_rt
run_action CONFIG_PATH_IN="$RT/tmp/$FORGED"
if keys_of "$LAST/env" | grep -q 'BASH_ENV'; then
  fail "runner file commands: a newline in config-path cannot forge a second entry" \
    "$(tr '\n' '|' <"$LAST/env")"
elif keys_of "$LAST/env" | grep -q '^BARE:\|^MALFORMED:'; then
  fail "runner file commands: a newline in config-path cannot forge a second entry" \
    "unparsed \$GITHUB_ENV content: $(tr '\n' '|' <"$LAST/env")"
else
  pass "runner file commands: a newline in config-path cannot forge a second entry"
fi

# ================================================================== manifest ==
note "mirror-url: scheme case"

# RFC 3986 §3.1 makes the scheme case-insensitive. Matching only the lowercase
# literal rejected a valid HTTPS URL AND told the author it was insecure.
run_action MIRROR_URL='HTTPS://mirror.example.com/tf/'
expect_ok "mirror-url scheme case: HTTPS:// is accepted" 'Wrote the terraform'
expect_config "mirror-url scheme case: the emitted scheme is normalised to lowercase" \
  "$(CFG)" 'https://mirror.example.com/tf/'

run_action MIRROR_URL='HTTP://mirror.example.com/tf/'
expect_fail "mirror-url scheme case: HTTP:// is still rejected" \
  '::error::mirror-url must start with https://'

note "written file"

# A composite action has no post step, so this file stays for the rest of the
# job at a path a later step may cache or upload as an artifact.
run_action
if [ "$STATUS" -eq 0 ]; then
  mode="$(stat -c '%a' "$(CFG)" 2>/dev/null || stat -f '%Lp' "$(CFG)")"
  if [ "$mode" = "600" ]; then
    pass "written file: the configuration is not readable by group or other"
  else
    fail "written file: the configuration is not readable by group or other" "mode is $mode"
  fi
else
  fail "written file: the configuration is not readable by group or other" "$(tail3)"
fi

# An unwritable destination used to surface as a raw interpreter message with no
# mention of config-path, unlike every other failure in this script.
new_rt
mkdir -p "$RT/tmp/locked"
chmod 500 "$RT/tmp/locked"
run_action CONFIG_PATH_IN="$RT/tmp/locked/.terraformrc"
chmod 700 "$LAST/tmp/locked"
expect_fail "written file: an unwritable destination is diagnosed as a config-path failure" \
  '::error::could not write the CLI configuration to config-path'

# The $GITHUB_ENV write applies to every later step in the caller's job and
# cannot be reverted, so replacing a value the caller already set is said out loud.
run_action TF_CLI_CONFIG_FILE=/home/runner/.terraformrc
expect_ok "written file: replacing an existing TF_CLI_CONFIG_FILE is announced" \
  '::warning::TF_CLI_CONFIG_FILE was already set to /home/runner/\.terraformrc and is replaced'

run_action
if printf '%s\n' "$OUT" | grep -q '::warning::TF_CLI_CONFIG_FILE was already set'; then
  fail "written file: no overwrite warning when nothing was set" "$(tail3)"
else
  pass "written file: no overwrite warning when nothing was set"
fi

note "manifest, workflows and docs"

# A composite action's ${{ }} expressions are substituted into the script text
# before bash parses it, so inputs must only ever arrive through env:.
if grep -q '\${{' "$T/mirror.sh"; then
  fail "manifest: no expression interpolation inside the run script" \
    "$(grep -n '\${{' "$T/mirror.sh" | head -3)"
else
  pass "manifest: no expression interpolation inside the run script"
fi

python3 - "$ACTION_YML" <<'PY' && pass "manifest: the advertised defaults are the safe ones" ||
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
i = d["inputs"]
assert i["allow-direct-fallback"]["default"] == "false", i["allow-direct-fallback"]
assert i["log-config"]["default"] == "false", i["log-config"]
assert i["binary"]["default"] == "terraform", i["binary"]
assert len(d["description"]) <= 125, len(d["description"])
# Terraform queries every matching installation method; the inputs must not be
# documented as a conditional fallback.
adf = " ".join(i["allow-direct-fallback"]["description"].split())
assert "not a conditional fallback" in adf, adf
assert "EVERY provider" in adf, adf
PY
  fail "manifest: the advertised defaults are the safe ones" "action.yml changed"

python3 - "$REPO_ROOT" <<'PY' && pass "workflows: every action is SHA-pinned and every workflow sets permissions" ||
import pathlib, re, sys, yaml
root = pathlib.Path(sys.argv[1]) / ".github" / "workflows"
bad = []
for wf in sorted(root.glob("*.yml")):
    text = wf.read_text()
    for line in text.splitlines():
        m = re.search(r"uses:\s*(\S+)", line)
        if not m or m.group(1).startswith("./"):
            continue
        ref = m.group(1)
        if not re.search(r"@[0-9a-f]{40}$", ref):
            bad.append("%s: %s is not SHA-pinned" % (wf.name, ref))
        elif "#" not in line.split("uses:")[1]:
            bad.append("%s: %s has no version comment" % (wf.name, ref))
    doc = yaml.safe_load(text)
    if "permissions" not in doc:
        bad.append("%s: no workflow-level permissions" % wf.name)
    for name, job in doc.get("jobs", {}).items():
        if "GITHUB_TOKEN" in text and "permissions" not in job and "permissions" not in doc:
            bad.append("%s/%s: no permissions" % (wf.name, name))
if bad:
    print("\n".join(bad))
    sys.exit(1)
PY
  fail "workflows: every action is SHA-pinned and every workflow sets permissions" "see above"

python3 - "$REPO_ROOT" <<'PY' && pass "docs: README documents the real installation-method semantics" ||
import pathlib, sys
readme = (pathlib.Path(sys.argv[1]) / "README.md").read_text()
missing = []
if "newest version" not in readme:
    missing.append("the newest-version-across-methods rule")
if "EVERY provider" not in readme:
    missing.append("the empty-patterns warning")
if "@" not in readme or not any(
    len(part.split()[0]) >= 40 for part in readme.split("terraform-provider-mirror@")[1:]
):
    missing.append("a SHA-pinned usage example")
if "takes precedence over" in readme:
    missing.append("(still claims include 'takes precedence over' exclude)")
if missing:
    print("README is missing: " + ", ".join(missing))
    sys.exit(1)
PY
  fail "docs: README documents the real installation-method semantics" "see above"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
