#!/usr/bin/env bash
# Offline feature tests: history persistence and local Git remotes only.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/history.sh
source "${ROOT}/lib/history.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir "$TMP/repository" "$TMP/reports"
JSON="$TMP/reports/report.json"
TEXT="$TMP/reports/report.txt"
SUMMARY="$TMP/reports/summary.md"
printf 'SMTP authentication: PASS for [Bingo email]\n' > "$TEXT"
printf '# Bingo findings\n\nSMTP authentication: PASS\n' > "$SUMMARY"

report() {
	jq -n --arg status "$1" --argjson code "$2" --argjson private "${3:-true}" \
		'{status:$status, exit_code:$code, private:$private, failures:(if $code == 0 then 0 else 1 end), warnings:2}' > "$JSON"
}
record() { omt_history_record "$1" "${3:-octomailtest-history}" "$2" "$JSON" "$TEXT" "$SUMMARY" "$TMP/repository"; }
expect_failure() {
	if "$@" > "$TMP/expected-error.log" 2>&1; then
		printf 'FAIL: expected rejection: %s\n' "$1" >&2
		exit 1
	fi
}

report passed 0
record Bingo 2
[[ "$OMT_HISTORY_COUNT" == 1 ]]
[[ "$OMT_HISTORY_INDEX" == "$TMP/repository/octomailtest-history/Bingo/README.md" ]]
report failed 124
record Bingo 2
report passed 0
record Bingo 2
STATE="$OMT_HISTORY_DIR/history.json"
jq -e '.total_runs == 3 and .passed_runs == 2 and .failed_runs == 1 and [.runs[].number] == [3,2] and .runs[1].exit_code == 124' "$STATE" >/dev/null
[[ ! -e "$OMT_HISTORY_DIR/runs/1" && -f "$OMT_HISTORY_DIR/runs/2/report.txt" ]]
grep -q 'runs/3/summary.md' "$OMT_HISTORY_INDEX"
grep -Eq 'T[0-9]{2}:[0-9]{2}:[0-9]{2}Z' "$OMT_HISTORY_INDEX"
cmp "$TEXT" "$OMT_HISTORY_DIR/runs/3/report.txt"
record Bingo 1
jq -e '.total_runs == 4 and (.runs | length) == 1 and .runs[0].number == 4' "$STATE" >/dev/null
[[ ! -e "$OMT_HISTORY_DIR/runs/2" && ! -e "$OMT_HISTORY_DIR/runs/3" ]]
record Tango 20
jq -e '.total_runs == 1' "$OMT_HISTORY_DIR/history.json" >/dev/null
jq -e '.total_runs == 4' "$STATE" >/dev/null
printf 'PASS: retained findings, timestamps, cumulative counters and independent aliases\n'

for keep in 0 -1 1.5 abc 01 999999999999999999; do expect_failure record Bingo "$keep"; done
for location in /tmp/elsewhere ../outside logs/../outside .git/logs logs//unsafe logs/./unsafe; do
	expect_failure record Bingo 10 "$location"
done
expect_failure record '../Bingo' 10
mkdir "$TMP/outside"
ln -s "$TMP/outside" "$TMP/repository/linked"
expect_failure record Bingo 10 linked/history
ln -s "$TMP/outside" "$TMP/repository/octomailtest-history/Unsafe"
expect_failure record Unsafe 10
cp "$STATE" "$TMP/unchanged.json"
report passed 0 false
expect_failure record Bingo 10
cmp "$STATE" "$TMP/unchanged.json"
report passed 0
mkdir "$TMP/repository/octomailtest-history/Bingo.lock"
expect_failure record Bingo 10
rmdir "$TMP/repository/octomailtest-history/Bingo.lock"
cmp "$STATE" "$TMP/unchanged.json"
printf 'private data\n' > "$TMP/repository/octomailtest-history/Bingo/unrelated.txt"
expect_failure record Bingo 10
rm "$TMP/repository/octomailtest-history/Bingo/unrelated.txt"
cmp "$STATE" "$TMP/unchanged.json"
printf '{broken json\n' > "$STATE"
expect_failure record Bingo 10
grep -q 'broken json' "$STATE"
cp "$TMP/unchanged.json" "$STATE"
rm "$TMP/repository/octomailtest-history/Bingo/runs/4/report.txt"
expect_failure record Bingo 10
cp "$TEXT" "$TMP/repository/octomailtest-history/Bingo/runs/4/report.txt"
cp "$TMP/unchanged.json" "$STATE"
printf 'PASS: invalid retention, unsafe paths, locks, corrupt history and privacy transitions rejected\n'

# A bare local remote proves that only the generated history is committed.
git init --bare -q "$TMP/remote.git"
git -C "$TMP/repository" init -q -b main
git -C "$TMP/repository" config user.name Test
git -C "$TMP/repository" config user.email test@example.invalid
printf 'baseline\n' > "$TMP/repository/README.md"
git -C "$TMP/repository" add README.md
git -C "$TMP/repository" commit -qm baseline
git -C "$TMP/repository" remote add origin "$TMP/remote.git"
git -C "$TMP/repository" push -q -u origin main
printf 'unrelated staged content\n' > "$TMP/repository/unrelated.txt"
git -C "$TMP/repository" add unrelated.txt
record Bingo 2
(
	cd "$TMP/repository"
	OMT_HISTORY_ALIAS=Bingo OMT_HISTORY_DIR="$TMP/repository/octomailtest-history/Bingo" \
		GITHUB_REF=refs/heads/main GITHUB_EVENT_NAME=workflow_dispatch \
		bash "$ROOT/action/commit-history.sh"
)
[[ "$(git -C "$TMP/repository" diff --cached --name-only)" == unrelated.txt ]]
[[ -z "$(git -C "$TMP/repository" ls-tree -r --name-only HEAD | grep -E 'unrelated|Tango' || true)" ]]
git --git-dir="$TMP/remote.git" show main:octomailtest-history/Bingo/history.json | jq -e '.total_runs == 5' >/dev/null
COUNT_BEFORE="$(git -C "$TMP/repository" rev-list --count HEAD)"
(
	cd "$TMP/repository"
	OMT_HISTORY_ALIAS=Bingo OMT_HISTORY_DIR="$TMP/repository/octomailtest-history/Bingo" \
		GITHUB_REF=refs/heads/main GITHUB_EVENT_NAME=schedule \
		bash "$ROOT/action/commit-history.sh"
)
[[ "$(git -C "$TMP/repository" rev-list --count HEAD)" == "$COUNT_BEFORE" ]]
(
	cd "$TMP/repository"
	expect_failure env OMT_HISTORY_ALIAS=Bingo OMT_HISTORY_DIR="$TMP/repository/octomailtest-history/Bingo" \
		GITHUB_REF=refs/pull/1/merge GITHUB_EVENT_NAME=pull_request bash "$ROOT/action/commit-history.sh"
)
printf 'PASS: scoped Git commits, authenticated push path, preserved unrelated index and no empty commits\n'

# A concurrent remote update must be preserved; the helper must not force-push.
git clone -q -b main "$TMP/remote.git" "$TMP/other"
git -C "$TMP/other" config user.name Other
git -C "$TMP/other" config user.email other@example.invalid
printf 'concurrent change\n' >> "$TMP/other/README.md"
git -C "$TMP/other" commit -qam concurrent
git -C "$TMP/other" push -q origin main
REMOTE_BEFORE="$(git --git-dir="$TMP/remote.git" rev-parse main)"
record Bingo 2
(
	cd "$TMP/repository"
	expect_failure env OMT_HISTORY_ALIAS=Bingo OMT_HISTORY_DIR="$TMP/repository/octomailtest-history/Bingo" \
		GITHUB_REF=refs/heads/main GITHUB_EVENT_NAME=schedule bash "$ROOT/action/commit-history.sh"
)
[[ "$(git --git-dir="$TMP/remote.git" rev-parse main)" == "$REMOTE_BEFORE" ]]
[[ "$(git -C "$TMP/repository" diff --cached --name-only)" == unrelated.txt ]]
printf 'PASS: concurrent remote changes rejected without force-push or unrelated index changes\n'
