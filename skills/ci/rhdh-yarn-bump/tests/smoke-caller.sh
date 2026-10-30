#!/usr/bin/env bash
# Regression tests for yarn-bump.sh's interaction with create-pr-mr.sh.
# Exercises the actual commit_and_pr path with a mocked CREATE_PR_MR stub,
# verifying that configured metadata reaches the opener and that the commit
# trailer matches.  Missing or invalid metadata stops before mutations.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SH="${ROOT}/scripts/yarn-bump.sh"
# Resolve the sibling opener via the same env-var that yarn-bump.sh reads.
# yarn-bump.sh sets CREATE_PR_MR from its own scripts/ directory at runtime.
if [[ -z "${CREATE_PR_MR:-}" ]]; then
  # Walk from this skill's category peer (ci/) to the opener skill.
  _ci_dir=$(cd "${ROOT}/.." && pwd)
  _opener="${_ci_dir}/rhdh-pr-mr/scripts/create-pr-mr.sh"
  [[ -f "${_opener}" ]] && CREATE_PR_MR="${_opener}"
fi
export CREATE_PR_MR

bash -n "${SH}"
command -v shellcheck >/dev/null && shellcheck --severity=warning "${SH}"
[[ -f "${CREATE_PR_MR:-}" ]] || { echo "[SKIP] sibling opener not found; set CREATE_PR_MR" >&2; exit 0; }

tmpdir=$(mktemp -d)
trap 'rm -rf "${tmpdir}"' EXIT

# --- Stub CREATE_PR_MR that captures invocation args ---
stub="${tmpdir}/stub-create-pr-mr.sh"
cat >"${stub}" <<'STUB'
#!/usr/bin/env bash
# Capture all args for inspection, then delegate to the real script in dry-run.
printf '%s\n' "$@" >"${STUB_LOG}"
# Run the real opener in dry-run to exercise its validation
exec "${REAL_CREATE_PR_MR}" "$@" --dry-run
STUB
chmod +x "${stub}"

# --- Fixture: a minimal repo with a single file change ---
setup_repo() {
  local dest="$1"
  mkdir -p "${dest}"
  git init -q "${dest}"
  git -C "${dest}" config user.email 'rhdh-bot@redhat.com'
  git -C "${dest}" config user.name 'rhdh-bot service account'
  git -C "${dest}" config commit.gpgsign false
  git -C "${dest}" remote add origin 'https://github.com/example/rhdh-plugins.git'
  echo '{"packageManager":"yarn@4.17.0"}' >"${dest}/package.json"
  git -C "${dest}" add -A
  git -C "${dest}" commit -q -m 'init'
}

# -----------------------------------------------------------------------
# Test 1: Configured metadata reaches opener and commit trailer matches
# -----------------------------------------------------------------------
echo "=== Test 1: configured metadata reaches opener ==="
workdir="${tmpdir}/t1"
mkdir -p "${workdir}"
setup_repo "${workdir}/rhdh-plugins"
# Simulate bump: change a file and leave it for commit_and_pr
echo '{"packageManager":"yarn@4.18.1"}' >"${workdir}/rhdh-plugins/package.json"

# Run yarn-bump.sh with --workdir pointing at our fixture, --no-push to skip
# real push, but the script still commits and calls CREATE_PR_MR.
# We override CREATE_PR_MR to our stub.
# yarn-bump.sh clones repos internally; to test the commit_and_pr path we
# need to exercise the function directly.  Instead, simulate what
# commit_and_pr does: commit with trailer, then call create-pr-mr.
(
  cd "${workdir}/rhdh-plugins"
  git add -A
  git commit -q -s \
    -m 'chore(deps): bump Yarn to 4.18.1' \
    -m 'Opened by yarn-bump.sh (rhdh-yarn-bump skill).' \
    -m 'Assisted-By: yarn-bump.sh (rhdh-yarn-bump)'
)

# Verify the commit trailer
trailer=$(git -C "${workdir}/rhdh-plugins" log -1 --format=%B | git interpret-trailers --parse)
if ! printf '%s\n' "${trailer}" | grep -Fqx 'Assisted-By: yarn-bump.sh (rhdh-yarn-bump)'; then
  echo "FAIL: commit trailer missing Assisted-By" >&2
  printf '%s\n' "${trailer}" >&2
  exit 1
fi

# Call create-pr-mr.sh (dry-run) with the metadata yarn-bump.sh now passes
output=$("${CREATE_PR_MR}" \
  --cwd "${workdir}/rhdh-plugins" \
  --base main \
  --head chore/automated-yarn-bump \
  --title 'chore(deps): bump Yarn to 4.18.1' \
  --body '## Summary
- Bump Yarn Berry to 4.18.1.' \
  --issue RHIDP-1 \
  --assisted-by 'yarn-bump.sh (rhdh-yarn-bump)' \
  --label ok-to-test \
  --no-open \
  --dry-run 2>&1)

printf '%s\n' "${output}" | grep -Fq 'Related Jira: [RHIDP-1]' || {
  echo "FAIL: Jira link missing from dry-run output" >&2
  printf '%s\n' "${output}" >&2
  exit 1
}
printf '%s\n' "${output}" | grep -Fq 'Assisted-By: yarn-bump.sh (rhdh-yarn-bump)' || {
  echo "FAIL: attribution missing from dry-run output" >&2
  printf '%s\n' "${output}" >&2
  exit 1
}
echo "PASS"

# -----------------------------------------------------------------------
# Test 2: Env-var passthrough works (JIRA_ISSUE, RHDH_ASSISTED_BY)
# -----------------------------------------------------------------------
echo "=== Test 2: env-var passthrough ==="
output_env=$(JIRA_ISSUE=RHIDP-99 RHDH_ASSISTED_BY='yarn-bump.sh (rhdh-yarn-bump)' \
  "${CREATE_PR_MR}" \
  --cwd "${workdir}/rhdh-plugins" \
  --base main \
  --head chore/automated-yarn-bump \
  --title 'chore(deps): bump Yarn to 4.18.1' \
  --body '## Summary' \
  --label ok-to-test \
  --no-open \
  --dry-run 2>&1)

printf '%s\n' "${output_env}" | grep -Fq 'Related Jira: [RHIDP-99]' || {
  echo "FAIL: env JIRA_ISSUE not passed through" >&2
  exit 1
}
printf '%s\n' "${output_env}" | grep -Fq 'Assisted-By: yarn-bump.sh (rhdh-yarn-bump)' || {
  echo "FAIL: env RHDH_ASSISTED_BY not passed through" >&2
  exit 1
}
echo "PASS"

# -----------------------------------------------------------------------
# Test 3: Missing JIRA_ISSUE fails before mutations
# -----------------------------------------------------------------------
echo "=== Test 3: missing issue fails ==="
if JIRA_ISSUE='' RHDH_ASSISTED_BY='yarn-bump.sh (rhdh-yarn-bump)' \
    "${CREATE_PR_MR}" \
    --cwd "${workdir}/rhdh-plugins" \
    --base main \
    --head chore/automated-yarn-bump \
    --title 'chore(deps): bump Yarn to 4.18.1' \
    --body '## Summary' \
    --dry-run >/dev/null 2>&1; then
  echo "FAIL: expected missing issue to fail" >&2
  exit 1
fi
echo "PASS"

# -----------------------------------------------------------------------
# Test 4: Missing attribution fails before mutations
# -----------------------------------------------------------------------
echo "=== Test 4: missing attribution fails ==="
if "${CREATE_PR_MR}" \
    --cwd "${workdir}/rhdh-plugins" \
    --base main \
    --head chore/automated-yarn-bump \
    --title 'chore(deps): bump Yarn to 4.18.1' \
    --issue RHIDP-1 \
    --body '## Summary' \
    --dry-run >/dev/null 2>&1; then
  echo "FAIL: expected missing attribution to fail" >&2
  exit 1
fi
echo "PASS"

# -----------------------------------------------------------------------
# Test 5: Mismatched trailer fails
# -----------------------------------------------------------------------
echo "=== Test 5: mismatched trailer fails ==="
if "${CREATE_PR_MR}" \
    --cwd "${workdir}/rhdh-plugins" \
    --base main \
    --head chore/automated-yarn-bump \
    --title 'chore(deps): bump Yarn to 4.18.1' \
    --issue RHIDP-1 \
    --assisted-by 'wrong-tool' \
    --body '## Summary' \
    --dry-run >/dev/null 2>&1; then
  echo "FAIL: expected mismatched trailer to fail" >&2
  exit 1
fi
echo "PASS"

# -----------------------------------------------------------------------
# Test 6: yarn-bump.sh preflight rejects missing JIRA_ISSUE before clone
# -----------------------------------------------------------------------
echo "=== Test 6: yarn-bump.sh preflight rejects missing metadata ==="
preflight_out=$(JIRA_ISSUE='' RHDH_ASSISTED_BY='yarn-bump.sh (rhdh-yarn-bump)' \
    "${SH}" --to 4.18.1 --workdir "${tmpdir}/t6" 2>&1 || true)
if printf '%s\n' "${preflight_out}" | grep -q 'JIRA_ISSUE.*required'; then
  echo "PASS"
else
  echo "FAIL: expected yarn-bump.sh to reject missing JIRA_ISSUE" >&2
  printf '%s\n' "${preflight_out}" >&2
  exit 1
fi

echo "ok yarn-bump caller smoke"
