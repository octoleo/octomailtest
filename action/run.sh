#!/usr/bin/env bash
#
# OctoMailTest GitHub Action - runner
#
# Runs src/mail and/or src/imap against the configured mailbox, captures
# everything into a report directory (text, JSON and Markdown) and hands
# the results to the next action steps through $GITHUB_OUTPUT.
#
# Diagnostic failures never make this script exit non-zero: the action's
# last step decides whether the job fails (input: fail-on-error). Only
# configuration errors (missing inputs, unknown mode, ...) abort here.
#
# Inputs arrive as OMT_* environment variables (see action.yml).

set -euo pipefail

#############################################
# Helpers
#############################################

escape_annotation() {
	# Escape a message for GitHub workflow commands (::error:: etc.).
	local s="$1"
	s="${s//%/%25}"
	s="${s//$'\r'/%0D}"
	s="${s//$'\n'/%0A}"
	printf '%s' "$s"
}

info()   { printf '%s\n' "$*"; }
notice() { printf '::notice title=OctoMailTest::%s\n' "$(escape_annotation "$*")"; }
warn()   { printf '::warning title=OctoMailTest::%s\n' "$(escape_annotation "$*")"; }
die()    { printf '::error title=OctoMailTest::%s\n' "$(escape_annotation "$*")" >&2; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }

ts()       { date -u +"%Y-%m-%dT%H:%M:%SZ"; }
ts_local() { date +"%Y-%m-%d %H:%M:%S"; }

lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
upper() { printf '%s' "$1" | tr '[:lower:]' '[:upper:]'; }

set_output() {
	# set_output <name> <single-line value>
	[[ -n "${GITHUB_OUTPUT:-}" ]] || return 0
	printf '%s=%s\n' "$1" "$2" >> "$GITHUB_OUTPUT"
}

parse_bool() {
	# parse_bool <input-name> <value> <default> -> true|false
	local v
	v="$(lower "${2:-}" | tr -d '[:space:]')"
	case "$v" in
		'')             printf '%s' "$3" ;;
		true|yes|on|1)  printf 'true' ;;
		false|no|off|0) printf 'false' ;;
		*) die "Input '${1}' must be true or false (got '${2}')." ;;
	esac
}

parse_uint() {
	# parse_uint <input-name> <value> <default> -> whole number
	# An empty value or 0 means "use the default".
	local v="${2:-}"
	v="${v//[[:space:]]/}"
	if [[ -z "$v" || "$v" == 0 ]]; then
		printf '%s' "$3"
		return 0
	fi
	[[ "$v" =~ ^[0-9]+$ ]] || die "Input '${1}' must be a whole number (got '${2}')."
	printf '%s' "$v"
}

format_duration() {
	printf '%dm %02ds' $(( $1 / 60 )) $(( $1 % 60 ))
}

# Markers used by src/mail for failures and warnings (bytes, not glyphs,
# so the parsing does not depend on the locale of the runner).
MARK_FAIL=$'\xe2\x9d\x8c'             # U+274C  cross mark
MARK_WARN=$'\xe2\x9a\xa0\xef\xb8\x8f' # U+26A0 U+FE0F warning sign

#############################################
# Inputs
#############################################

ACTION_PATH="${OMT_ACTION_PATH:-${GITHUB_ACTION_PATH:-}}"
if [[ -z "$ACTION_PATH" || ! -f "${ACTION_PATH}/src/mail" || ! -f "${ACTION_PATH}/src/imap" ]]; then
	die "Cannot find the OctoMailTest scripts under '${ACTION_PATH:-<empty>}'."
fi

VERSION="$(tr -d '[:space:]' < "${ACTION_PATH}/VERSION" 2>/dev/null || true)"
[[ -n "$VERSION" ]] || VERSION=unknown

MODE="$(lower "${OMT_MODE:-}")"
[[ -n "$MODE" ]] || MODE=both
case "$MODE" in
	mail|imap|both) ;;
	*) die "Input 'mode' must be one of mail, imap or both (got '${OMT_MODE}')." ;;
esac

# Inputs win over OCTOMAILTEST_* variables already present in the job env,
# which in turn win over the config file (same precedence as the scripts).
DOMAIN="${OMT_DOMAIN:-${OCTOMAILTEST_DOMAIN:-}}"
HOST="${OMT_HOST:-${OCTOMAILTEST_HOST:-}}"
EMAIL="${OMT_EMAIL:-${OCTOMAILTEST_EMAIL:-}}"
PASS="${OMT_PASS:-${OCTOMAILTEST_PASS:-}}"
CONFIG_FILE="${OMT_CONFIG_FILE:-}"

IMAP_PORT="$(parse_uint imap-port "${OMT_IMAP_PORT:-${OCTOMAILTEST_IMAP_PORT:-}}" '')"
SMTP_PORT="$(parse_uint smtp-port "${OMT_SMTP_PORT:-${OCTOMAILTEST_SMTP_PORT:-}}" '')"
SIEVE_PORT="$(parse_uint sieve-port "${OMT_SIEVE_PORT:-${OCTOMAILTEST_SIEVE_PORT:-}}" '')"
TIMEOUT="$(parse_uint timeout "${OMT_TIMEOUT:-}" 900)"
RETENTION_DAYS="$(parse_uint retention-days "${OMT_RETENTION_DAYS:-}" '')"

QUIET="$(parse_bool quiet "${OMT_QUIET:-}" false)"
UPLOAD_ARTIFACT="$(parse_bool upload-artifact "${OMT_UPLOAD_ARTIFACT:-}" true)"
FAIL_ON_ERROR="$(parse_bool fail-on-error "${OMT_FAIL_ON_ERROR:-}" true)"
STEP_SUMMARY="$(parse_bool step-summary "${OMT_STEP_SUMMARY:-}" true)"
ANNOTATIONS="$(parse_bool annotations "${OMT_ANNOTATIONS:-}" true)"

ARTIFACT_NAME="${OMT_ARTIFACT_NAME:-}"
[[ -n "$ARTIFACT_NAME" ]] || ARTIFACT_NAME=octomailtest-report

REPORT_DIR="${OMT_REPORT_DIR:-}"
[[ -n "$REPORT_DIR" ]] || REPORT_DIR=octomailtest-report
[[ "$REPORT_DIR" == /* ]] || REPORT_DIR="${PWD}/${REPORT_DIR}"

CONFIG_ARGS=()
if [[ -n "$CONFIG_FILE" ]]; then
	[[ -f "$CONFIG_FILE" ]] || die "Input 'config-file' points to a file that does not exist: ${CONFIG_FILE}"
	CONFIG_ARGS=(-c "$CONFIG_FILE")
fi

HAS_CONFIG=false
if [[ -n "$CONFIG_FILE" || -f ./.octomailtest ]]; then
	HAS_CONFIG=true
fi

# Secrets that only live in a config file must still be masked and scrubbed.
# They are read in a throw-away subshell and never exported, so the scripts
# keep their own precedence rules.
MASK_PASS="$PASS"
MASK_EMAIL="$EMAIL"
if [[ "$HAS_CONFIG" == true ]]; then
	cfg="${CONFIG_FILE:-./.octomailtest}"
	if [[ -z "$MASK_PASS" ]]; then
		MASK_PASS="$(bash -c 'source "$1" >/dev/null 2>&1; printf "%s" "${PASS:-}"' _ "$cfg" 2>/dev/null || true)"
	fi
	if [[ -z "$MASK_EMAIL" ]]; then
		MASK_EMAIL="$(bash -c 'source "$1" >/dev/null 2>&1; printf "%s" "${EMAIL:-}"' _ "$cfg" 2>/dev/null || true)"
	fi
fi

# Never let the password reach the logs, even when it was not given as a secret.
if [[ -n "$MASK_PASS" ]]; then
	printf '::add-mask::%s\n' "$(escape_annotation "$MASK_PASS")"
fi

if [[ "$HAS_CONFIG" == false ]]; then
	MISSING=()
	[[ -n "$HOST" ]]  || MISSING+=(host)
	[[ -n "$EMAIL" ]] || MISSING+=(email)
	[[ -n "$PASS" ]]  || MISSING+=(pass)
	if (( ${#MISSING[@]} > 0 )); then
		die "Missing required input(s): ${MISSING[*]}. Pass them under 'with:' (use a secret for 'pass') or point 'config-file' at an .octomailtest file."
	fi
fi

#############################################
# Tool check (the installer step normally took care of this)
#############################################

MISSING_TOOLS=()
for tool in bash openssl dig nc timeout date base64 awk grep sed head jq; do
	have "$tool" || MISSING_TOOLS+=("$tool")
done
if (( ${#MISSING_TOOLS[@]} > 0 )); then
	die "Required tools are missing on this runner: ${MISSING_TOOLS[*]}. Keep 'install-dependencies: true' (the default) or install them before running the action."
fi
have swaks || warn "swaks is not installed: the SMTP AUTH and send-to-self tests will be skipped."

#############################################
# Environment for the diagnostic scripts
#############################################

[[ -n "$DOMAIN" ]]     && export OCTOMAILTEST_DOMAIN="$DOMAIN"
[[ -n "$HOST" ]]       && export OCTOMAILTEST_HOST="$HOST"
[[ -n "$EMAIL" ]]      && export OCTOMAILTEST_EMAIL="$EMAIL"
[[ -n "$PASS" ]]       && export OCTOMAILTEST_PASS="$PASS"
[[ -n "$IMAP_PORT" ]]  && export OCTOMAILTEST_IMAP_PORT="$IMAP_PORT"
[[ -n "$SMTP_PORT" ]]  && export OCTOMAILTEST_SMTP_PORT="$SMTP_PORT"
[[ -n "$SIEVE_PORT" ]] && export OCTOMAILTEST_SIEVE_PORT="$SIEVE_PORT"
export OCTOMAILTEST_CI=1

effective_port() {
	# effective_port <input value> <script default>
	if [[ -n "$1" ]]; then
		printf '%s' "$1"
	else
		printf '%s' "$2"
	fi
}

describe_port() {
	# describe_port <input value> <script default> -> text for the report header
	if [[ -n "$1" ]]; then
		printf '%s' "$1"
	elif [[ "$HAS_CONFIG" == true ]]; then
		printf '%s (default, unless the config file sets it)' "$2"
	else
		printf '%s (default)' "$2"
	fi
}

IMAP_PORT_EFFECTIVE="$(effective_port "$IMAP_PORT" 993)"
SMTP_PORT_EFFECTIVE="$(effective_port "$SMTP_PORT" 587)"
SIEVE_PORT_EFFECTIVE="$(effective_port "$SIEVE_PORT" 4190)"

#############################################
# Report files
#############################################

mkdir -p "$REPORT_DIR"
REPORT_TXT="${REPORT_DIR}/report.txt"
REPORT_JSON="${REPORT_DIR}/report.json"
SUMMARY_MD="${REPORT_DIR}/summary.md"
: > "$REPORT_TXT"

TMP_DIR="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/octomailtest.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

STARTED_AT="$(ts)"
START_EPOCH="$(date +%s)"

RUN_URL=""
if [[ -n "${GITHUB_SERVER_URL:-}" && -n "${GITHUB_REPOSITORY:-}" && -n "${GITHUB_RUN_ID:-}" ]]; then
	RUN_URL="${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}"
fi

{
	echo "#################################################"
	echo "# OctoMailTest ${VERSION} - GitHub Action report"
	echo "#################################################"
	echo "# Started:     ${STARTED_AT}"
	echo "# Mode:        ${MODE}"
	echo "# Domain:      ${DOMAIN:-(not set)}"
	echo "# Host:        ${HOST:-(from config file)}"
	echo "# Mailbox:     ${EMAIL:-(from config file)}"
	echo "# IMAP port:   $(describe_port "$IMAP_PORT" 993)"
	echo "# SMTP port:   $(describe_port "$SMTP_PORT" 587)"
	echo "# Sieve port:  $(describe_port "$SIEVE_PORT" 4190)"
	echo "# Config file: ${CONFIG_FILE:-(none)}"
	echo "# Runner:      ${RUNNER_OS:-$(uname -s)} ${RUNNER_ARCH:-$(uname -m)}${RUNNER_NAME:+ (${RUNNER_NAME})}"
	if [[ -n "${GITHUB_REPOSITORY:-}" ]]; then
		echo "# Workflow:    ${GITHUB_REPOSITORY} run ${GITHUB_RUN_NUMBER:-?} (id ${GITHUB_RUN_ID:-?}, attempt ${GITHUB_RUN_ATTEMPT:-1})"
	fi
	if [[ -n "$RUN_URL" ]]; then
		echo "# Run URL:     ${RUN_URL}"
	fi
	echo "#################################################"
	echo
} | tee -a "$REPORT_TXT"

#############################################
# Run the diagnostics
#############################################

FILTER=(cat)
if [[ "$QUIET" == true ]]; then
	FILTER=(sed '/^=====/d')   # same as the --ci flag of the Docker image
fi

MAIL_STATUS=skipped
MAIL_RC=""
IMAP_STATUS=skipped
IMAP_RC=""

run_script() {
	# run_script <mail|imap> -> sets RESULT_STATUS and RESULT_RC
	local label="$1"
	local script="${ACTION_PATH}/src/${label}"
	local out="${TMP_DIR}/${label}.out"
	local rc

	printf '::group::%s diagnostics (src/%s)\n' "$label" "$label"
	: > "$out"
	set +e
	timeout -k 15 "$TIMEOUT" bash "$script" ${CONFIG_ARGS[@]+"${CONFIG_ARGS[@]}"} < /dev/null 2>&1 \
		| "${FILTER[@]}" | tee -a "$REPORT_TXT" "$out"
	rc=${PIPESTATUS[0]}
	set -e
	printf '::endgroup::\n'

	case "$rc" in
		0)
			RESULT_STATUS=passed
			;;
		124|137)
			RESULT_STATUS=timeout
			printf '[%s] %s %s diagnostics timed out after %ss (raise the timeout input)\n' \
				"$(ts_local)" "$MARK_FAIL" "$label" "$TIMEOUT" | tee -a "$REPORT_TXT" "$out"
			;;
		*)
			RESULT_STATUS=failed
			if ! grep -qF -- "$MARK_FAIL" "$out"; then
				printf '[%s] %s %s diagnostics exited with code %s\n' \
					"$(ts_local)" "$MARK_FAIL" "$label" "$rc" | tee -a "$REPORT_TXT" "$out"
			fi
			;;
	esac
	RESULT_RC="$rc"
}

case "$MODE" in
	mail)
		run_script mail
		MAIL_STATUS="$RESULT_STATUS"; MAIL_RC="$RESULT_RC"
		;;
	imap)
		run_script imap
		IMAP_STATUS="$RESULT_STATUS"; IMAP_RC="$RESULT_RC"
		;;
	both)
		run_script mail
		MAIL_STATUS="$RESULT_STATUS"; MAIL_RC="$RESULT_RC"
		printf -- '----------------------------------------\n' | tee -a "$REPORT_TXT"
		run_script imap
		IMAP_STATUS="$RESULT_STATUS"; IMAP_RC="$RESULT_RC"
		;;
esac

#############################################
# Scrub secrets from everything that is kept
#############################################

SECRETS=()
if [[ -n "$MASK_PASS" ]]; then
	SECRETS+=("$MASK_PASS")
	SECRETS+=("$(printf '%s' "$MASK_PASS" | base64 | tr -d '\n')")
	if [[ -n "$MASK_EMAIL" ]]; then
		# SASL PLAIN blob used by the ManageSieve authentication test.
		SECRETS+=("$(printf '\0%s\0%s' "$MASK_EMAIL" "$MASK_PASS" | base64 | tr -d '\n')")
	fi
fi

scrub_file() {
	local f="$1" content s
	[[ -s "$f" ]] || return 0
	(( ${#SECRETS[@]} > 0 )) || return 0
	content="$(<"$f")"
	for s in "${SECRETS[@]}"; do
		[[ -n "$s" ]] && content="${content//"$s"/********}"
	done
	printf '%s\n' "$content" > "$f"
}

for f in "$REPORT_TXT" "${TMP_DIR}/mail.out" "${TMP_DIR}/imap.out"; do
	if [[ -f "$f" ]]; then
		scrub_file "$f"
	fi
done

#############################################
# Collect failures and warnings
#############################################

collect_marks() {
	# collect_marks <marker> <file...> -> messages carrying <marker>,
	# without the "[timestamp] <marker>" prefix, one per line.
	local mark="$1"
	shift
	# Everything up to the marker is dropped: the scripts sometimes print a
	# label without a newline first ("Port 25: [timestamp] <marker> ...").
	cat "$@" 2>/dev/null \
		| grep -F -- "$mark" \
		| grep -vF -- 'Critical failures:' \
		| sed -e "s/^.*${mark}//" -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
		| grep -v '^$' \
		|| true
}

FAIL_FILE="${TMP_DIR}/failures.txt"
WARN_FILE="${TMP_DIR}/warnings.txt"
collect_marks "$MARK_FAIL" "${TMP_DIR}/mail.out" "${TMP_DIR}/imap.out" > "$FAIL_FILE"
collect_marks "$MARK_WARN" "${TMP_DIR}/mail.out" "${TMP_DIR}/imap.out" > "$WARN_FILE"
FAILURES="$(wc -l < "$FAIL_FILE" | tr -d '[:space:]')"
WARNINGS="$(wc -l < "$WARN_FILE" | tr -d '[:space:]')"

STATUS=passed
EXIT_CODE=0
for st_rc in "${MAIL_STATUS}:${MAIL_RC}" "${IMAP_STATUS}:${IMAP_RC}"; do
	st="${st_rc%%:*}"
	rc="${st_rc#*:}"
	case "$st" in
		failed|timeout)
			STATUS=failed
			if (( EXIT_CODE == 0 )); then
				EXIT_CODE="$rc"
			fi
			;;
	esac
done

#############################################
# Report footer
#############################################

FINISHED_AT="$(ts)"
DURATION=$(( $(date +%s) - START_EPOCH ))
RESULT_LABEL="$(upper "$STATUS")"

describe_result() {
	# describe_result <status> <exit code>
	case "$1" in
		passed)  printf 'PASSED (exit 0)' ;;
		failed)  printf 'FAILED (exit %s)' "$2" ;;
		timeout) printf 'TIMED OUT after %ss' "$TIMEOUT" ;;
		skipped) printf 'SKIPPED (mode: %s)' "$MODE" ;;
	esac
}

{
	echo
	echo "#################################################"
	echo "# OctoMailTest summary"
	echo "#################################################"
	echo "# Mail diagnostics:  $(describe_result "$MAIL_STATUS" "$MAIL_RC")"
	echo "# IMAP diagnostics:  $(describe_result "$IMAP_STATUS" "$IMAP_RC")"
	echo "# Critical failures: ${FAILURES}"
	echo "# Warnings:          ${WARNINGS}"
	echo "# Finished:          ${FINISHED_AT} (duration $(format_duration "$DURATION"))"
	echo "# Result:            ${RESULT_LABEL}"
	echo "#################################################"
} | tee -a "$REPORT_TXT"

#############################################
# JSON report
#############################################

jq -n \
	--arg tool octomailtest \
	--arg version "$VERSION" \
	--arg action "$MODE" \
	--arg status "$STATUS" \
	--argjson exit_code "$EXIT_CODE" \
	--argjson failures "$FAILURES" \
	--argjson warnings "$WARNINGS" \
	--arg started_at "$STARTED_AT" \
	--arg finished_at "$FINISHED_AT" \
	--argjson duration_seconds "$DURATION" \
	--arg domain "$DOMAIN" \
	--arg host "$HOST" \
	--arg email "$EMAIL" \
	--argjson imap_port "$IMAP_PORT_EFFECTIVE" \
	--argjson smtp_port "$SMTP_PORT_EFFECTIVE" \
	--argjson sieve_port "$SIEVE_PORT_EFFECTIVE" \
	--arg config_file "$CONFIG_FILE" \
	--arg mail_status "$MAIL_STATUS" \
	--arg mail_exit "$MAIL_RC" \
	--arg imap_status "$IMAP_STATUS" \
	--arg imap_exit "$IMAP_RC" \
	--argjson timeout "$TIMEOUT" \
	--rawfile failure_lines "$FAIL_FILE" \
	--rawfile warning_lines "$WARN_FILE" \
	--arg runner_os "${RUNNER_OS:-$(uname -s)}" \
	--arg runner_arch "${RUNNER_ARCH:-$(uname -m)}" \
	--arg runner_name "${RUNNER_NAME:-}" \
	--arg repository "${GITHUB_REPOSITORY:-}" \
	--arg run_id "${GITHUB_RUN_ID:-}" \
	--arg run_number "${GITHUB_RUN_NUMBER:-}" \
	--arg run_attempt "${GITHUB_RUN_ATTEMPT:-}" \
	--arg sha "${GITHUB_SHA:-}" \
	--arg ref "${GITHUB_REF:-}" \
	--arg run_url "$RUN_URL" \
	--rawfile output "$REPORT_TXT" \
	'{
		tool: $tool,
		version: $version,
		action: $action,
		status: $status,
		exit_code: $exit_code,
		failures: $failures,
		warnings: $warnings,
		started_at: $started_at,
		finished_at: $finished_at,
		duration_seconds: $duration_seconds,
		timeout_seconds: $timeout,
		target: {
			domain: $domain,
			host: $host,
			email: $email,
			imap_port: $imap_port,
			smtp_port: $smtp_port,
			sieve_port: $sieve_port,
			config_file: (if $config_file == "" then null else $config_file end)
		},
		checks: {
			mail: { status: $mail_status, exit_code: (if $mail_exit == "" then null else ($mail_exit | tonumber) end) },
			imap: { status: $imap_status, exit_code: (if $imap_exit == "" then null else ($imap_exit | tonumber) end) }
		},
		failure_messages: ($failure_lines | split("\n") | map(select(length > 0))),
		warning_messages: ($warning_lines | split("\n") | map(select(length > 0))),
		runner: { os: $runner_os, arch: $runner_arch, name: $runner_name },
		workflow: {
			repository: $repository,
			run_id: $run_id,
			run_number: $run_number,
			run_attempt: $run_attempt,
			sha: $sha,
			ref: $ref,
			url: $run_url
		},
		output: $output
	}' > "$REPORT_JSON"

#############################################
# Markdown summary
#############################################

MAX_INLINE_REPORT=400000   # bytes of report.txt embedded in the job summary (limit is 1 MiB)

result_cell() {
	# result_cell <status> <exit code> -> Markdown table cell
	case "$1" in
		passed)  printf ':white_check_mark: passed' ;;
		failed)  printf ':x: failed (exit %s)' "$2" ;;
		timeout) printf ':alarm_clock: timed out after %ss' "$TIMEOUT" ;;
		skipped) printf ':fast_forward: skipped' ;;
	esac
}

if [[ "$STATUS" == passed ]]; then
	HEADLINE=':white_check_mark: PASSED'
else
	HEADLINE=':x: FAILED'
fi

{
	echo "## :email: OctoMailTest report: ${HEADLINE}"
	echo
	echo "| Target | |"
	echo "|---|---|"
	echo "| Domain | ${DOMAIN:-_(not set)_} |"
	echo "| Host | ${HOST:-_(from config file)_} |"
	echo "| Mailbox | ${EMAIL:-_(from config file)_} |"
	echo "| Ports | IMAP ${IMAP_PORT_EFFECTIVE} / SMTP ${SMTP_PORT_EFFECTIVE} / Sieve ${SIEVE_PORT_EFFECTIVE} |"
	echo "| Mode | \`${MODE}\` |"
	echo "| Started | ${STARTED_AT} |"
	echo "| Duration | $(format_duration "$DURATION") |"
	echo "| Version | OctoMailTest ${VERSION} |"
	echo
	echo "| Diagnostic | Result |"
	echo "|---|---|"
	echo "| Mail (\`src/mail\`) | $(result_cell "$MAIL_STATUS" "$MAIL_RC") |"
	echo "| IMAP (\`src/imap\`) | $(result_cell "$IMAP_STATUS" "$IMAP_RC") |"
	echo
	echo "**Critical failures:** ${FAILURES} / **Warnings:** ${WARNINGS}"
	echo
	if (( FAILURES > 0 )); then
		echo "### :x: Failures"
		echo
		while IFS= read -r line; do
			echo "- ${line}"
		done < "$FAIL_FILE"
		echo
	fi
	if (( WARNINGS > 0 )); then
		echo "### :warning: Warnings"
		echo
		while IFS= read -r line; do
			echo "- ${line}"
		done < "$WARN_FILE"
		echo
	fi
	echo "<details>"
	echo "<summary>:page_facing_up: Full report (report.txt)</summary>"
	echo
	echo '```text'
	if (( $(wc -c < "$REPORT_TXT") > MAX_INLINE_REPORT )); then
		head -c "$MAX_INLINE_REPORT" "$REPORT_TXT"
		echo
		echo "... (report truncated here, download the artifact for the full text)"
	else
		cat "$REPORT_TXT"
	fi
	echo '```'
	echo
	echo "</details>"
} > "$SUMMARY_MD"

#############################################
# Annotations
#############################################

if [[ "$ANNOTATIONS" == true ]]; then
	n=0
	while IFS= read -r line; do
		n=$((n + 1))
		if (( n > 25 )); then
			printf '::error title=OctoMailTest::... and %d more failures, see the report\n' $((FAILURES - 25))
			break
		fi
		printf '::error title=OctoMailTest::%s\n' "$(escape_annotation "$line")"
	done < "$FAIL_FILE"
	if (( WARNINGS > 0 )); then
		first_warning="$(head -n 1 "$WARN_FILE")"
		warn "${WARNINGS} warning(s) in the OctoMailTest report, first: ${first_warning}"
	fi
	if [[ "$STATUS" == passed ]]; then
		notice "All critical mail checks passed for ${HOST:-the configured host} (${WARNINGS} warning(s))."
	fi
fi

#############################################
# Outputs
#############################################

set_output status "$STATUS"
set_output exit-code "$EXIT_CODE"
set_output failures "$FAILURES"
set_output warnings "$WARNINGS"
set_output report-dir "$REPORT_DIR"
set_output report-file "$REPORT_TXT"
set_output report-json "$REPORT_JSON"
set_output summary-file "$SUMMARY_MD"
set_output artifact-name "$ARTIFACT_NAME"
set_output upload-artifact "$UPLOAD_ARTIFACT"
set_output retention-days "$RETENTION_DAYS"
set_output fail-on-error "$FAIL_ON_ERROR"
set_output step-summary "$STEP_SUMMARY"

echo
echo "================================================="
echo " OctoMailTest result: ${RESULT_LABEL} (${FAILURES} critical failure(s), ${WARNINGS} warning(s))"
echo " Report directory:    ${REPORT_DIR}"
echo "================================================="
