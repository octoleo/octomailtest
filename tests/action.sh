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
if [[ -n "${MOCK_PORT_SETTINGS_FILE:-}" ]]; then
	printf '%s\n' "${OCTOMAILTEST_SMTP_RELAY_PORT:-unset}" "${OCTOMAILTEST_SMTP_PORT:-unset}" \
		"${OCTOMAILTEST_SMTPS_PORT:-unset}" "${OCTOMAILTEST_IMAP_PORT:-unset}" \
		"${OCTOMAILTEST_IMAPS_PORT:-unset}" "${OCTOMAILTEST_SIEVE_PORT:-unset}" \
		> "$MOCK_PORT_SETTINGS_FILE"
fi
[[ -z "${MOCK_DOMAIN_FILE:-}" ]] || printf '%s\n' "${OCTOMAILTEST_DOMAIN:-unset}" > "$MOCK_DOMAIN_FILE"
if [[ "$MOCK_SCENARIO" == stream ]]; then
	IFS= read -r -t 15 release < "$MOCK_RELEASE_FIFO"
	[[ "$release" == continue ]]
fi
printf 'Mail domain %s; mailbox %s\n' "${OCTOMAILTEST_DOMAIN:-unset}" "$OCTOMAILTEST_EMAIL"
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
# Fixture exports are intentionally confined to this subshell and its child.
# shellcheck disable=SC2030,SC2031
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
		if [[ "$line" == 'SMTP connectivity on [Bingo host]:[Bingo port]' ]]; then
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
grep -qF 'SMTP connectivity on [Bingo host]:[Bingo port]' live-report/report.txt
grep -q 'SMTP authentication: PASS' live-report/report.txt
jq -e '.status == "passed" and .exit_code == 0' live-report/report.json >/dev/null
jq -e '.total_runs == 1 and .passed_runs == 1' live-history/Bingo/history.json >/dev/null
if grep -RE 'private\.example|other\.example\.net|198\.51\.100\.27|mock-password' live-report live-history "$TEMP/live.log"; then
	echo 'FAIL: live action output or its retained reports exposed an identifier.' >&2
	exit 1
fi

# Only host, email and password are needed; ports are optional overrides.
# Each fixture intentionally confines its exported values to its own subshell.
# shellcheck disable=SC2030,SC2031
check_port_settings() (
	local label="$1" field value index=0
	shift
	local ports=("$@") defaults=(25 587 465 143 993 4190) expected=()
	local fields=(SMTP_RELAY_PORT SMTP_PORT SMTPS_PORT IMAP_PORT IMAPS_PORT SIEVE_PORT)
	unset OCTOMAILTEST_DOMAIN
	export OMT_DOMAIN='' OMT_HISTORY=false OMT_PRIVATE=false OMT_REPORT_DIR="ports-$label" MOCK_SCENARIO=pass
	export GITHUB_OUTPUT="$TEMP/ports-$label.outputs" MOCK_PORT_SETTINGS_FILE="$TEMP/ports-$label.settings"
	export MOCK_DOMAIN_FILE="$TEMP/ports-$label.domain"
	: > "$TEMP/ports-$label.expected"
	for field in "${fields[@]}"; do
		unset "OCTOMAILTEST_$field"
		value="${ports[$index]}"
		export "OMT_$field=$value"
		if [[ -z "$value" || "$value" == 0 ]]; then
			printf 'unset\n' >> "$TEMP/ports-$label.expected"
			expected+=("${defaults[$index]}")
		else
			printf '%s\n' "$value" >> "$TEMP/ports-$label.expected"
			expected+=("$value")
		fi
		index=$((index + 1))
	done
	bash "$TEMP/action/action/execute.sh" > "$TEMP/ports-$label.log" 2>&1
	cmp "$TEMP/ports-$label.expected" "$MOCK_PORT_SETTINGS_FILE"
	[[ "$(cat "$MOCK_DOMAIN_FILE")" == private.example ]]
	jq -e --argjson relay "${expected[0]}" --argjson smtp "${expected[1]}" --argjson smtps "${expected[2]}" \
		--argjson imap "${expected[3]}" --argjson imaps "${expected[4]}" --argjson sieve "${expected[5]}" \
		'.status == "passed" and .target.domain == "private.example"
		 and .target.smtp_relay_port == $relay and .target.smtp_port == $smtp and .target.smtps_port == $smtps
		 and .target.imap_port == $imap and .target.imaps_port == $imaps and .target.sieve_port == $sieve' \
		"ports-$label/report.json" >/dev/null
	for role in 'SMTP relay port' 'SMTP submission port' 'SMTPS port' 'IMAP port' 'IMAPS port' 'Sieve port'; do
		grep -q "$role" "ports-$label/report.txt"
		grep -q "$role" "ports-$label/summary.md"
	done
	if [[ "$label" == custom ]]; then
		# Privacy changes published reports, never the ports sent to diagnostics.
		export OMT_PRIVATE=true OMT_REPORT_DIR=ports-private
		bash "$TEMP/action/action/execute.sh" > "$TEMP/ports-private.log" 2>&1
		cmp "$TEMP/ports-$label.expected" "$MOCK_PORT_SETTINGS_FILE"
		jq -e '.target.smtp_relay_port == "[Bingo SMTP relay port]"
			and .target.smtp_port == "[Bingo SMTP port]" and .target.smtps_port == "[Bingo SMTPS port]"
			and .target.imap_port == "[Bingo IMAP port]" and .target.imaps_port == "[Bingo IMAPS port]"
			and .target.sieve_port == "[Bingo Sieve port]"' ports-private/report.json >/dev/null
		if grep -RE 'private\.example|other\.example\.net|198\.51\.100\.27|mock-password|25250|25870|24650|21143|21993|24190' ports-private "$TEMP/ports-private.log"; then
			echo 'FAIL: private action exposed identifying values or configured ports.' >&2; exit 1
		fi
	fi
)
check_port_settings defaults '' '' '' '' '' ''
check_port_settings zero-defaults 0 0 0 0 0 0
check_port_settings custom 25250 25870 24650 21143 21993 24190

# Input omission/zero preserves environment settings; nonzero inputs override them.
# shellcheck disable=SC2030,SC2031
(
	export OMT_SMTP_RELAY_PORT=0 OMT_SMTP_PORT='' OMT_SMTPS_PORT=0 OMT_IMAP_PORT='' OMT_IMAPS_PORT=0 OMT_SIEVE_PORT=''
	export OCTOMAILTEST_SMTP_RELAY_PORT=25250 OCTOMAILTEST_SMTP_PORT=25870 OCTOMAILTEST_SMTPS_PORT=24650
	export OCTOMAILTEST_IMAP_PORT=21143 OCTOMAILTEST_IMAPS_PORT=21993 OCTOMAILTEST_SIEVE_PORT=24190
	export OMT_HISTORY=false OMT_PRIVATE=false OMT_REPORT_DIR=ports-environment MOCK_SCENARIO=pass
	export GITHUB_OUTPUT="$TEMP/ports-environment.outputs" MOCK_PORT_SETTINGS_FILE="$TEMP/ports-environment.settings"
	bash "$TEMP/action/action/execute.sh" > "$TEMP/ports-environment.log" 2>&1
	printf '25250\n25870\n24650\n21143\n21993\n24190\n' > "$TEMP/ports-environment.expected"
	cmp "$TEMP/ports-environment.expected" "$MOCK_PORT_SETTINGS_FILE"
	export OMT_SMTP_PORT=35870 OMT_IMAPS_PORT=31993 OMT_REPORT_DIR=ports-inputs
	bash "$TEMP/action/action/execute.sh" > "$TEMP/ports-inputs.log" 2>&1
	printf '25250\n35870\n24650\n21143\n31993\n24190\n' > "$TEMP/ports-inputs.expected"
	cmp "$TEMP/ports-inputs.expected" "$MOCK_PORT_SETTINGS_FILE"
)

# Config-only values remain the engine's responsibility and are not overwritten.
# shellcheck disable=SC2030,SC2031
(
	for field in SMTP_RELAY_PORT SMTP_PORT SMTPS_PORT IMAP_PORT IMAPS_PORT SIEVE_PORT; do
		unset "OCTOMAILTEST_$field"
		export "OMT_$field="
	done
	printf 'SMTP_RELAY_PORT=25250\nSMTP_PORT=25870\nSMTPS_PORT=24650\nIMAP_PORT=21143\nIMAPS_PORT=21993\nSIEVE_PORT=24190\n' > "$TEMP/ports-config"
	export OMT_CONFIG_FILE="$TEMP/ports-config" OMT_HISTORY=false OMT_PRIVATE=false OMT_REPORT_DIR=ports-config MOCK_SCENARIO=pass
	export GITHUB_OUTPUT="$TEMP/ports-config.outputs" MOCK_PORT_SETTINGS_FILE="$TEMP/ports-config.settings"
	bash "$TEMP/action/action/execute.sh" > "$TEMP/ports-config.log" 2>&1
	printf 'unset\nunset\nunset\nunset\nunset\nunset\n' > "$TEMP/ports-config.expected"
	cmp "$TEMP/ports-config.expected" "$MOCK_PORT_SETTINGS_FILE"
	jq -e '.target.smtp_relay_port == null and .target.smtp_port == null and .target.smtps_port == null
		and .target.imap_port == null and .target.imaps_port == null and .target.sieve_port == null' ports-config/report.json >/dev/null
	grep -q 'config file' ports-config/summary.md
)

# Domain overrides remain optional; each of the three connection inputs is required.
# shellcheck disable=SC2030,SC2031
(
	export OMT_DOMAIN=override.example OMT_HISTORY=false OMT_REPORT_DIR=domain-override MOCK_SCENARIO=pass
	export GITHUB_OUTPUT="$TEMP/domain-override.outputs" MOCK_DOMAIN_FILE="$TEMP/domain-override.value"
	bash "$TEMP/action/action/execute.sh" > "$TEMP/domain-override.log" 2>&1
	[[ "$(cat "$MOCK_DOMAIN_FILE")" == override.example ]]
	for missing in HOST EMAIL PASS; do
		(
			unset "OCTOMAILTEST_$missing"
			export "OMT_$missing=" OMT_REPORT_DIR="missing-$missing"
			bash "$TEMP/action/action/execute.sh" > "$TEMP/missing-$missing.log" 2>&1
			jq -e '.status == "failed" and .exit_code != 0' "missing-$missing/report.json" >/dev/null
		)
	done
)
# Invalid port input remains a failed run rather than silently using a default.
# shellcheck disable=SC2030,SC2031
(
	export OMT_SMTPS_PORT=invalid OMT_HISTORY=false OMT_REPORT_DIR=ports-invalid
	export GITHUB_OUTPUT="$TEMP/ports-invalid.outputs"
	bash "$TEMP/action/action/execute.sh" > "$TEMP/ports-invalid.log" 2>&1
	jq -e '.status == "failed" and .exit_code != 0' ports-invalid/report.json >/dev/null
	grep -q "Input 'smtps-port' must be a whole number" "$TEMP/ports-invalid.log"
)
echo 'PASS: action privacy, outcomes, history, optional port forwarding and three-input setup'
