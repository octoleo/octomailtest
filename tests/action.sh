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
if [[ -n "${MOCK_SMTP_SETTINGS_FILE:-}" ]]; then
	printf '%s\n' "${OCTOMAILTEST_SMTP_PORT:-unset}" "${OCTOMAILTEST_SMTP_TLS_MODE:-unset}" \
		"${OCTOMAILTEST_SMTP_STARTTLS_PORT:-unset}" "${OCTOMAILTEST_SMTPS_PORT:-unset}" \
		> "$MOCK_SMTP_SETTINGS_FILE"
fi
if [[ "$MOCK_SCENARIO" == stream ]]; then
	IFS= read -r -t 15 release < "$MOCK_RELEASE_FIFO"
	[[ "$release" == continue ]]
fi
printf 'Mail domain %s; mailbox %s\n' "$OCTOMAILTEST_DOMAIN" "$OCTOMAILTEST_EMAIL"
printf 'Resolved IP: 198.51.100.27; PTR: other.example.net\n'
printf 'TLS protocol: TLSv1.3; cipher: TLS_AES_256_GCM_SHA384\n'
printf 'Certificate expires in 72 days\n'
printf 'Password: %s\n' "$OCTOMAILTEST_PASS" >&2
case "$MOCK_SCENARIO" in
	pass|stream) printf 'SMTP authentication: PASS\n' ;;
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

# Exercise the full action pipeline while a diagnostic waits for the consumer
# to receive its first result. Only then may it produce the remaining findings.
(
	mkfifo "$TEMP/action-release" "$TEMP/action-live-output"
	exec 8<> "$TEMP/action-release"
	(
		exec 8>&-
		export MOCK_SCENARIO=stream MOCK_RELEASE_FIFO="$TEMP/action-release"
		export OMT_TIMEOUT=20 OMT_HISTORY_DIR=live-history OMT_REPORT_DIR=live-report
		export GITHUB_OUTPUT="$TEMP/live.outputs"
		exec timeout 30 bash "$TEMP/action/action/execute.sh"
	) > "$TEMP/action-live-output" 2>&1 &
	action_pid=$!
	trap 'exec 8>&- 9>&-; kill "$action_pid" 2>/dev/null || true; wait "$action_pid" 2>/dev/null || true' EXIT
	exec 9< "$TEMP/action-live-output"
	deadline=$((SECONDS + 5))
	live_result=false
	while (( SECONDS < deadline )); do
		IFS= read -r -t "$((deadline - SECONDS))" line <&9 || break
		printf '%s\n' "$line" >> "$TEMP/live.log"
		if [[ "$line" == 'SMTP connectivity on [Bingo host]:587' ]]; then
			live_result=true
			break
		fi
	done
	if [[ "$live_result" != true ]]; then
		echo 'FAIL: action withheld diagnostic output while the test was running.' >&2
		exit 1
	fi
	[[ ! -e live-report/report.json ]]
	kill -0 "$action_pid"
	printf 'continue\n' >&8
	exec 8>&-
	cat <&9 >> "$TEMP/live.log"
	wait "$action_pid"
	exec 9>&-
	trap - EXIT
)
grep -q 'SMTP authentication: PASS' "$TEMP/live.log"
grep -q 'Detailed IMAP test completed' "$TEMP/live.log"
grep -q 'SMTP connectivity on \[Bingo host\]:587' live-report/report.txt
grep -q 'SMTP authentication: PASS' live-report/report.txt
jq -e '.status == "passed" and .exit_code == 0' live-report/report.json >/dev/null
jq -e '.total_runs == 1 and .passed_runs == 1' live-history/Bingo/history.json >/dev/null
if grep -RE 'private\.example|other\.example\.net|198\.51\.100\.27|mock-password' live-report live-history "$TEMP/live.log"; then
	echo 'FAIL: live action output or its retained reports exposed an identifier.' >&2
	exit 1
fi

# The action forwards transport configuration to both diagnostics while reports
# distinguish the submission connection from the dedicated protocol checks.
check_smtp_settings() (
	local label="$1" port="$2" mode="$3" starttls_port="$4" smtps_port="$5"
	local expected_mode="$6" expected_starttls="$7" expected_smtps="$8"
	local expected_port="$port" expected_export_mode
	unset OCTOMAILTEST_SMTP_PORT OCTOMAILTEST_SMTP_TLS_MODE OCTOMAILTEST_SMTP_STARTTLS_PORT OCTOMAILTEST_SMTPS_PORT
	export OMT_SMTP_PORT="$port" OMT_SMTP_TLS_MODE="$mode"
	export OMT_SMTP_STARTTLS_PORT="$starttls_port" OMT_SMTPS_PORT="$smtps_port"
	export OMT_HISTORY=false OMT_REPORT_DIR="smtp-$label" MOCK_SCENARIO=pass
	export GITHUB_OUTPUT="$TEMP/smtp-$label.outputs" MOCK_SMTP_SETTINGS_FILE="$TEMP/smtp-$label.settings"
	bash "$TEMP/action/action/execute.sh" > "$TEMP/smtp-$label.log" 2>&1
	[[ -n "$expected_port" && "$expected_port" != 0 ]] || expected_port=587
	expected_export_mode="$(printf '%s' "$mode" | tr '[:upper:]' '[:lower:]')"
	{
		for value in "$port" "$expected_export_mode" "$starttls_port" "$smtps_port"; do
			if [[ -z "$value" || "$value" == 0 ]]; then printf 'unset\n'; else printf '%s\n' "$value"; fi
		done
	} > "$TEMP/smtp-$label.expected"
	cmp "$TEMP/smtp-$label.expected" "$MOCK_SMTP_SETTINGS_FILE"
	jq -e --argjson port "$expected_port" --arg mode "$expected_mode" \
		--argjson starttls "$expected_starttls" --argjson smtps "$expected_smtps" \
		'.status == "passed" and .target.smtp_port == $port and .target.smtp_tls_mode == $mode
		 and .target.smtp_starttls_port == $starttls and .target.smtps_port == $smtps' \
		"smtp-$label/report.json" >/dev/null
	grep -q 'SMTP submission TLS:' "smtp-$label/report.txt"
	grep -q 'SMTP STARTTLS port' "smtp-$label/summary.md"
	grep -q 'SMTPS port' "smtp-$label/summary.md"
	if grep -RE 'private\.example|other\.example\.net|198\.51\.100\.27|mock-password' "smtp-$label" "$TEMP/smtp-$label.log"; then
		echo 'FAIL: SMTP transport reporting exposed an identifier.' >&2
		exit 1
	fi
)
check_smtp_settings defaults '' '' '' '' starttls 587 465
check_smtp_settings auto-smtps 465 auto 0 0 implicit 587 465
check_smtp_settings implicit-custom 2465 IMPLICIT 2587 2466 implicit 2587 2466
check_smtp_settings starttls-custom 2587 starttls 0 0 starttls 2587 465

# Unset action inputs retain the environment fallback and config-file precedence.
(
	export OMT_SMTP_PORT='' OMT_SMTP_TLS_MODE='' OMT_SMTP_STARTTLS_PORT='' OMT_SMTPS_PORT=''
	export OCTOMAILTEST_SMTP_PORT=2465 OCTOMAILTEST_SMTP_TLS_MODE=implicit
	export OCTOMAILTEST_SMTP_STARTTLS_PORT=2587 OCTOMAILTEST_SMTPS_PORT=3465
	export OMT_HISTORY=false OMT_REPORT_DIR=smtp-environment MOCK_SCENARIO=pass
	export GITHUB_OUTPUT="$TEMP/smtp-environment.outputs" MOCK_SMTP_SETTINGS_FILE="$TEMP/smtp-environment.settings"
	bash "$TEMP/action/action/execute.sh" > "$TEMP/smtp-environment.log" 2>&1
	printf '2465\nimplicit\n2587\n3465\n' > "$TEMP/smtp-environment.expected"
	cmp "$TEMP/smtp-environment.expected" "$MOCK_SMTP_SETTINGS_FILE"
	jq -e '.target.smtp_port == 2465 and .target.smtp_tls_mode == "implicit"
		and .target.smtp_starttls_port == 2587 and .target.smtps_port == 3465' smtp-environment/report.json >/dev/null
	# Explicit inputs win, and 0 removes an inherited dedicated-port override.
	export OMT_SMTP_PORT=465 OMT_SMTP_TLS_MODE=auto OMT_SMTP_STARTTLS_PORT=0 OMT_SMTPS_PORT=0
	export OMT_REPORT_DIR=smtp-inputs
	bash "$TEMP/action/action/execute.sh" > "$TEMP/smtp-inputs.log" 2>&1
	printf '465\nauto\nunset\nunset\n' > "$TEMP/smtp-inputs.expected"
	cmp "$TEMP/smtp-inputs.expected" "$MOCK_SMTP_SETTINGS_FILE"
	jq -e '.target.smtp_port == 465 and .target.smtp_tls_mode == "implicit"
		and .target.smtp_starttls_port == 587 and .target.smtps_port == 465' smtp-inputs/report.json >/dev/null
)
(
	unset OCTOMAILTEST_SMTP_PORT OCTOMAILTEST_SMTP_TLS_MODE OCTOMAILTEST_SMTP_STARTTLS_PORT OCTOMAILTEST_SMTPS_PORT
	export OMT_SMTP_PORT='' OMT_SMTP_TLS_MODE='' OMT_SMTP_STARTTLS_PORT='' OMT_SMTPS_PORT=''
	printf 'SMTP_PORT=2465\nSMTP_TLS_MODE=implicit\nSMTP_STARTTLS_PORT=2587\nSMTPS_PORT=3465\n' > "$TEMP/smtp-config"
	export OMT_CONFIG_FILE="$TEMP/smtp-config" OMT_HISTORY=false OMT_REPORT_DIR=smtp-config MOCK_SCENARIO=pass
	export GITHUB_OUTPUT="$TEMP/smtp-config.outputs" MOCK_SMTP_SETTINGS_FILE="$TEMP/smtp-config.settings"
	bash "$TEMP/action/action/execute.sh" > "$TEMP/smtp-config.log" 2>&1
	printf 'unset\nunset\nunset\nunset\n' > "$TEMP/smtp-config.expected"
	cmp "$TEMP/smtp-config.expected" "$MOCK_SMTP_SETTINGS_FILE"
	jq -e '.target.smtp_port == null and .target.smtp_tls_mode == null
		and .target.smtp_starttls_port == null and .target.smtps_port == null' smtp-config/report.json >/dev/null
	grep -q 'from config file' smtp-config/summary.md
)
(
	export OMT_SMTP_TLS_MODE=unsupported OMT_HISTORY=false OMT_REPORT_DIR=smtp-invalid
	export GITHUB_OUTPUT="$TEMP/smtp-invalid.outputs"
	bash "$TEMP/action/action/execute.sh" > "$TEMP/smtp-invalid.log" 2>&1
	jq -e '.status == "failed" and .exit_code != 0' smtp-invalid/report.json >/dev/null
	grep -q "Input 'smtp-tls-mode' must be auto, starttls or implicit" "$TEMP/smtp-invalid.log"
)
echo 'PASS: action privacy, outcomes, history, report paths, SMTP transport forwarding and reporting'
