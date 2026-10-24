#!/usr/bin/env bash
# Action-boundary tests use fake diagnostics and never contact a mail server.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEMP="$(mktemp -d)"
TEMP="$(cd "$TEMP" && pwd -P)"
trap 'rm -rf -- "$TEMP"' EXIT
mkdir -p "$TEMP/action/action" "$TEMP/action/src" "$TEMP/action/lib" "$TEMP/bin" "$TEMP/work"
cp "$ROOT/action/run.sh" "$ROOT/action/execute.sh" "$TEMP/action/action/"
cp "$ROOT/lib/privacy.sh" "$ROOT/lib/history.sh" "$TEMP/action/lib/"
cp "$ROOT/VERSION" "$TEMP/action/"
for tool in dig nc swaks; do
	printf '#!/usr/bin/env bash\nexit 0\n' > "$TEMP/bin/$tool"
	chmod +x "$TEMP/bin/$tool"
done
cat > "$TEMP/action/src/mail" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf 'SMTP connectivity on %s:587\n' "$OCTOMAILTEST_HOST"
printf 'Mail domain %s; mailbox %s\n' "$OCTOMAILTEST_DOMAIN" "$OCTOMAILTEST_EMAIL"
printf 'Resolved IP: 198.51.100.27; PTR: other.example.net\n'
printf 'TLS protocol: TLSv1.3; cipher: TLS_AES_256_GCM_SHA384\n'
printf 'Certificate expires in 72 days\n'
printf 'Password: %s\n' "$OCTOMAILTEST_PASS" >&2
case "$MOCK_SCENARIO" in
	pass) printf 'SMTP authentication: PASS\n' ;;
	fail) printf '[mock] ❌ Authentication failed at other.example.net\n' >&2; exit 1 ;;
	timeout) sleep 3 ;;
esac
MOCK
printf '#!/usr/bin/env bash\nprintf "Detailed IMAP test completed\\n"\n' > "$TEMP/action/src/imap"
cd "$TEMP/work"
export PATH="$TEMP/bin:$PATH"
export RUNNER_TEMP="$TEMP"
export OMT_ACTION_PATH="$TEMP/action" OMT_PRIVATE=true OMT_ALIAS=Bingo OMT_HISTORY=true OMT_HISTORY_KEEP=2
export OMT_DOMAIN=private.example OMT_HOST=mx.private.example OMT_EMAIL=mailbox@private.example
export OMT_PASS='S3cret.$ with quotes' OMT_MODE=both OMT_TIMEOUT=1 OMT_REPORT_DIR=report
export OMT_UPLOAD_ARTIFACT=false OMT_STEP_SUMMARY=true OMT_ANNOTATIONS=true
for scenario in pass fail timeout; do
	export MOCK_SCENARIO="$scenario" GITHUB_OUTPUT="$TEMP/$scenario.outputs"
	bash "$TEMP/action/action/execute.sh" > "$TEMP/$scenario.log" 2>&1
	if [[ "$scenario" == pass ]]; then
		jq -e '.status == "passed" and .exit_code == 0' report/report.json >/dev/null
	else
		jq -e '.status == "failed" and .exit_code != 0' report/report.json >/dev/null
	fi
	grep -q 'TLSv1.3' "$TEMP/$scenario.log"
	grep -q 'TLS_AES_256_GCM_SHA384' "$TEMP/$scenario.log"
	grep -q '72 days' "$TEMP/$scenario.log"
	grep -q 'Bingo host' "$TEMP/$scenario.log"
	if grep -RE 'private\.example|other\.example\.net|198\.51\.100\.27|S3cret' report octomailtest-history "$TEMP/$scenario.log"; then
		echo 'FAIL: private action leaked a test identifier.' >&2; exit 1
	fi
done
jq -e '.total_runs == 3 and .passed_runs == 1 and .failed_runs == 2 and (.runs|length) == 2' octomailtest-history/Bingo/history.json >/dev/null
[[ ! -e octomailtest-history/Bingo/runs/1 ]]
export OMT_PASS='' GITHUB_OUTPUT="$TEMP/missing.outputs"
bash "$TEMP/action/action/execute.sh" > "$TEMP/missing.log" 2>&1
jq -e '.status == "failed" and .exit_code != 0' report/report.json >/dev/null
jq -e '.total_runs == 4 and .failed_runs == 3' octomailtest-history/Bingo/history.json >/dev/null
grep -q '^status=failed$' "$TEMP/missing.outputs"
mkdir protected
printf 'keep\n' > protected/report.json
ln -s protected unsafe
if OMT_REPORT_DIR=unsafe bash "$TEMP/action/action/execute.sh" > "$TEMP/unsafe.log" 2>&1; then
	echo 'FAIL: action accepted a symlink report directory.' >&2; exit 1
fi
[[ "$(cat protected/report.json)" == keep ]]

# Public metadata must not bypass the filter.
export OMT_PASS=mock-password MOCK_SCENARIO=pass GITHUB_OUTPUT="$TEMP/metadata.outputs"
OMT_REPORT_DIR=private.example-report OMT_ARTIFACT_NAME=private.example-report RUNNER_NAME=SecretRunner \
	bash "$TEMP/action/action/execute.sh" > "$TEMP/metadata.log" 2>&1
grep -q '^artifact-name=octomailtest-Bingo$' "$TEMP/metadata.outputs"
metadata_report="$(sed -n 's/^report-json=//p' "$TEMP/metadata.outputs")"
if grep -E 'private\.example|SecretRunner' "$TEMP/metadata.outputs" "$TEMP/metadata.log" "$metadata_report"; then
	echo 'FAIL: public metadata exposed an identifier.' >&2; exit 1
fi

# A config that exits early cannot leave the filter with unknown credentials.
# shellcheck disable=SC2016
printf 'PASS=ConfigOnlySecret\nprintf "%%s\\n" "$PASS"\nexit 0\n' > .octomailtest
export GITHUB_OUTPUT="$TEMP/config.outputs"
bash "$TEMP/action/action/execute.sh" > "$TEMP/config.log" 2>&1
grep -q '^status=failed$' "$TEMP/config.outputs"
if grep -R 'ConfigOnlySecret' report octomailtest-history "$TEMP/config.log"; then
	echo 'FAIL: incomplete configuration escaped anonymization.' >&2; exit 1
fi
rm .octomailtest

# Auto-commit history belongs to its own checkout, not the caller working tree.
mkdir .octomailtest-history-repository
before="$(jq -r .total_runs octomailtest-history/Bingo/history.json)"
export GITHUB_OUTPUT="$TEMP/isolated.outputs"
OMT_HISTORY_COMMIT=true GITHUB_WORKSPACE="$PWD" bash "$TEMP/action/action/execute.sh" > "$TEMP/isolated.log" 2>&1
jq -e '.total_runs == 1' .octomailtest-history-repository/octomailtest-history/Bingo/history.json >/dev/null
[[ "$(jq -r .total_runs octomailtest-history/Bingo/history.json)" == "$before" ]]
echo 'PASS: action privacy, outcomes, failure history, retention and report paths'
