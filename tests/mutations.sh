#!/usr/bin/env bash
#
# Mutation harness: disables one guard at a time and re-runs run-tests.sh
# against the mutated action.yml, so every guard has to be shown to be load
# bearing rather than merely present.
#
# Why this exists: a guard that is inert passes review, passes CI, and protects
# nothing. Two real examples from this repository:
#
#   * the charset allow-lists were evaluated with bash `[[ =~ ]]` under the
#     runner's default en_US.UTF-8 locale, where a bracket RANGE collates
#     accented letters INSIDE [A-Za-z] — so `https://exämple.com/` satisfied a
#     guard whose own error message says non-ASCII is rejected. The guard was
#     present, tested and wrong.
#
#   * a mutation that fails to apply looks exactly like a guard that is working.
#     Every mutation below therefore aborts if its anchor is not found.
#
# Usage:  tests/mutations.sh            run every mutation
#         tests/mutations.sh <name>...  run only the named ones
#
# Exit status is 0 when EVERY guard proved load bearing (its mutation made at
# least one case fail), non-zero otherwise.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

# Guards neutralised by replacing their tagged call with a no-op. These are the
# ones whose absence simply removes a check.
LINE_GUARDS=(
  pattern-allowlist
  mirror-url-required
  mirror-url-mask
  mirror-url-charset
  mirror-url-authority
  binary
  bool-allow-direct
  bool-log-config
  config-path-charset
  config-path-symlink
  config-path-containment
  config-path-filename
  config-path-regular
  scheme-case
  config-file-mode
  env-overwrite-warning
  write-diagnostic
)

mutate_line_guard() { # <guard-name> <src> <dst>
  awk -v g="# GUARD:$1" '
    index($0, g) { sub(/^([[:space:]]*)/, "&: # MUTATED "); print; next }
    { print }
  ' "$2" >"$3"
}

# Guards that need a specific wrong-but-plausible replacement rather than
# removal, because deleting them changes the shape of the output instead of
# weakening a check.
mutate_special() { # <guard-name> <src> <dst>
  case "$1" in
    env-heredoc)
      # Revert to the single-line key=value form a newline can forge past.
      sed "s|printf '%s<<%s\\\\n%s\\\\n%s\\\\n' \"\$2\" \"\$delim\" \"\$3\" \"\$delim\" >> \"\$1\" # GUARD:env-heredoc|printf '%s=%s\\\\n' \"\$2\" \"\$3\" >> \"\$1\" # MUTATED|" "$2" >"$3"
      ;;
    config-path-canonical)
      # Stop resolving the path, so containment is checked on the raw value.
      sed 's|dest="$(canonicalize "$dest")" # GUARD:config-path-canonical|: # MUTATED|' "$2" >"$3"
      ;;
    charset-locale)
      # The historical bug: drop the LC_ALL=C that forces byte-wise matching,
      # so the allow-list ranges collate by the runner's UTF-8 locale again.
      sed 's|^\( *\)local LC_ALL=C$|\1: # MUTATED|' "$2" >"$3"
      ;;
    *) return 1 ;;
  esac
}

SPECIAL_GUARDS=(env-heredoc config-path-canonical charset-locale)

run_one() { # <guard-name>
  local g="$1" mutant="$T/action-$1.yml" out="$T/out-$1"
  if printf '%s\n' "${SPECIAL_GUARDS[@]}" | grep -qx "$g"; then
    mutate_special "$g" "$REPO_ROOT/action.yml" "$mutant"
  else
    mutate_line_guard "$g" "$REPO_ROOT/action.yml" "$mutant"
  fi

  if cmp -s "$REPO_ROOT/action.yml" "$mutant"; then
    printf 'NO-OP  %-26s mutation did not change action.yml — anchor missing\n' "$g"
    return 1
  fi
  if ! python3 -c "import yaml,sys; yaml.safe_load(open(sys.argv[1]))" "$mutant" 2>/dev/null; then
    printf 'BROKEN %-26s mutated action.yml no longer parses\n' "$g"
    return 1
  fi

  set +e
  ACTION_YML="$mutant" "$REPO_ROOT/tests/run-tests.sh" >"$out" 2>&1
  set -e

  local failed
  failed="$(grep -c '^FAIL' "$out" || true)"
  if [ "$failed" -eq 0 ]; then
    printf 'INERT  %-26s no case failed — this guard is not load bearing\n' "$g"
    return 1
  fi
  printf 'ok     %-26s %s case(s) fail:\n' "$g" "$failed"
  grep '^FAIL' "$out" | sed 's/^FAIL /           - /'
  return 0
}

TARGETS=("$@")
if [ "${#TARGETS[@]}" -eq 0 ]; then
  TARGETS=("${LINE_GUARDS[@]}" "${SPECIAL_GUARDS[@]}")
fi

echo "=== baseline (unmutated) ==="
if ! "$REPO_ROOT/tests/run-tests.sh" >"$T/baseline" 2>&1; then
  echo "baseline suite is not green; fix that before trusting any mutation" >&2
  tail -5 "$T/baseline" >&2
  exit 1
fi
tail -1 "$T/baseline"

echo
echo "=== mutations ==="
BAD=0
for g in "${TARGETS[@]}"; do
  run_one "$g" || BAD=$((BAD + 1))
done

echo
if [ "$BAD" -eq 0 ]; then
  echo "all ${#TARGETS[@]} guards are load bearing"
else
  echo "$BAD of ${#TARGETS[@]} guards did not prove load bearing"
fi
exit "$BAD"
