#!/usr/bin/env bash
# Smoke tests for create-pr-mr.sh (no network).
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SH="${ROOT}/scripts/create-pr-mr.sh"

bash -n "${SH}"
command -v shellcheck >/dev/null && shellcheck --severity=warning "${SH}"

out=$("${SH}" --help)
printf '%s\n' "${out}" | grep -q 'create-pr-mr.sh' || {
  echo "help missing usage" >&2
  exit 1
}

tmpdir=$(mktemp -d)
trap 'rm -rf "${tmpdir}"' EXIT
git init -q "${tmpdir}"
git -C "${tmpdir}" config user.email 'test@example.com'
git -C "${tmpdir}" config user.name 'test'
git -C "${tmpdir}" config commit.gpgsign false
git -C "${tmpdir}" remote add origin 'https://github.com/example/rhdh-plugins.git'
git -C "${tmpdir}" commit --allow-empty -q -m 'init' \
  -m 'Assisted-By: Codex (5.6 Sol High)'

dry=$("${SH}" --cwd "${tmpdir}" --base main --head chore/test --title 'chore: test' \
  --issue RHIDP-1 --assisted-by 'Codex (5.6 Sol High)' --dry-run)
printf '%s\n' "${dry}" | grep -q 'title=chore: test \[main\]' || {
  echo "expected title suffix [main]" >&2
  exit 1
}
printf '%s\n' "${dry}" | grep -Fq 'Related Jira: [RHIDP-1](https://redhat.atlassian.net/browse/RHIDP-1)' || {
  echo "expected Markdown Jira link" >&2
  exit 1
}
printf '%s\n' "${dry}" | grep -Fq 'Assisted-By: Codex (5.6 Sol High)' || {
  echo "expected model-specific attribution" >&2
  exit 1
}

if "${SH}" --cwd "${tmpdir}" --base main --head chore/test --title 'chore: test' \
  --assisted-by 'Codex (5.6 Sol High)' --dry-run >/dev/null 2>&1; then
  echo "expected missing Jira issue to fail" >&2
  exit 1
fi

if "${SH}" --cwd "${tmpdir}" --base main --head chore/test --title 'chore: test' \
  --issue RHIDP-1 --dry-run >/dev/null 2>&1; then
  echo "expected missing attribution to fail" >&2
  exit 1
fi

if "${SH}" --cwd "${tmpdir}" --base main --head chore/test --title 'chore: test' \
  --issue RHIDP-1 --assisted-by 'Codex (5.6 Luna Medium)' --dry-run >/dev/null 2>&1; then
  echo "expected mismatched commit attribution to fail" >&2
  exit 1
fi

echo "ok create-pr-mr smoke"
