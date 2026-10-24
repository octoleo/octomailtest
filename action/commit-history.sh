#!/usr/bin/env bash
# Commit only the generated alias history using an isolated Git index.
# The caller checks out the destination branch with authenticated credentials.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/history.sh
source "${SCRIPT_DIR}/../lib/history.sh"

fail() { omt_history_error "$1"; exit 1; }

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || fail 'History commits require a checked-out repository.'
ROOT="$(cd "$ROOT" && pwd -P)"
ALIAS="${OMT_HISTORY_ALIAS:-}"
DIRECTORY="${OMT_HISTORY_DIR:-}"
omt_history_alias_valid "$ALIAS" || fail 'History commits require a valid public alias.'
case "$DIRECTORY" in
	"${ROOT}/"*) RELATIVE="${DIRECTORY#"${ROOT}/"}" ;;
	*) fail 'Only history inside the checked-out repository can be committed.' ;;
esac
[[ "${DIRECTORY##*/}" == "$ALIAS" ]] || fail 'The history directory does not match the alias.'
[[ "$(omt_history_resolve_dir "$ROOT" "$RELATIVE")" == "$DIRECTORY" ]] || fail 'The history path is unsafe.'
omt_history_tree_valid "$DIRECTORY" || fail 'Only generated history files can be committed.'
PRIVATE="$(jq -r '.private' "${DIRECTORY}/history.json" 2>/dev/null)" || fail 'The history state is missing.'
omt_history_state_valid "${DIRECTORY}/history.json" "$ALIAS" "$PRIVATE" || fail 'The history state is invalid.'
COUNT="$(jq -r '.total_runs' "${DIRECTORY}/history.json")"

case "${GITHUB_EVENT_NAME:-}" in
	pull_request*) fail 'History commits are disabled for pull request events.' ;;
esac
if [[ -n "${GITHUB_REF:-}" && "$GITHUB_REF" != refs/heads/* ]]; then
	fail 'History commits require a branch event.'
fi
BRANCH="$(git symbolic-ref --quiet --short HEAD 2>/dev/null)" || fail 'History commits require a checked-out branch.'
if [[ -n "${OMT_HISTORY_BRANCH:-}" && "$BRANCH" != "$OMT_HISTORY_BRANCH" ]]; then
	fail 'The checked-out branch does not match the history destination.'
fi
if [[ -n "${GITHUB_REF:-}" && "refs/heads/${BRANCH}" != "$GITHUB_REF" ]]; then
	fail 'The checked-out branch does not match the workflow branch.'
fi

git check-ref-format --branch "$BRANCH" >/dev/null 2>&1 || fail 'The destination branch is invalid.'
HEAD_SHA="$(git rev-parse HEAD)"
INDEX="$(mktemp "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/octomailtest-index.XXXXXX")"
rm -f "$INDEX"
trap 'rm -f "$INDEX" "${INDEX}.lock"' EXIT
export GIT_INDEX_FILE="$INDEX"
git read-tree "$HEAD_SHA" >/dev/null 2>&1 || fail 'Cannot prepare the history commit.'
git --literal-pathspecs add -A -- "$RELATIVE" >/dev/null 2>&1 || fail 'Cannot stage generated history.'
if git diff --cached --quiet >/dev/null 2>&1; then
	printf 'OctoMailTest history: no new history to commit.\n'
	exit 0
else
	DIFF_STATUS=$?
	[[ "$DIFF_STATUS" == 1 ]] || fail 'Cannot inspect the proposed history commit.'
fi
# Validate deleted paths too: do not commit unrelated removed files.
while IFS= read -r -d '' CHANGED; do
	case "$CHANGED" in
		"${RELATIVE}/"*) OWNED="${CHANGED#"${RELATIVE}/"}" ;;
		*) fail 'The proposed commit includes files outside the alias history.' ;;
	esac
	[[ "$OWNED" == history.json || "$OWNED" == README.md || "$OWNED" =~ ^runs/[1-9][0-9]*/(report\.json|report\.txt|summary\.md)$ ]] || fail 'The proposed history commit contains an unrelated file.'
done < <(git diff --cached --name-only -z)
TREE="$(git write-tree 2>/dev/null)" || fail 'Cannot prepare the history tree.'
COMMIT="$(printf 'Record %s test run %s\n' "$ALIAS" "$COUNT" | git -c user.name='github-actions[bot]' -c user.email='41898282+github-actions[bot]@users.noreply.github.com' commit-tree "$TREE" -p "$HEAD_SHA" 2>/dev/null)" || fail 'Cannot create the history commit.'
git update-ref "refs/heads/${BRANCH}" "$COMMIT" "$HEAD_SHA" >/dev/null 2>&1 || fail 'The local branch changed while recording history; no update was applied.'
unset GIT_INDEX_FILE
# Synchronize only our generated subtree; unrelated staged changes stay staged.
git --literal-pathspecs reset -q HEAD -- "$RELATIVE" >/dev/null 2>&1 || fail 'Cannot synchronize the history index.'
# Do not force-push or rebase: concurrent branch changes must be reviewed/retried.
git push origin "${COMMIT}:refs/heads/${BRANCH}" >/dev/null 2>&1 || fail 'Cannot push history. Check write permissions, branch rules and repository-wide workflow concurrency; no force push was attempted.'
printf 'OctoMailTest history: recorded %s run %s.\n' "$ALIAS" "$COUNT"
