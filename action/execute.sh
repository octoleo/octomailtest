#!/usr/bin/env bash
# Optional output privacy and history around the unchanged diagnostic runner.
set +x
set -euo pipefail

ACTION_PATH="${OMT_ACTION_PATH:-${GITHUB_ACTION_PATH:-}}"
[[ -f "$ACTION_PATH/action/run.sh" ]] || { echo '::error::OctoMailTest installation is incomplete.'; exit 1; }

boolean() {
	case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
		''|false|no|off|0) printf false ;;
		true|yes|on|1) printf true ;;
		*) echo '::error::OctoMailTest boolean option is invalid.' >&2; return 1 ;;
	esac
}

PRIVATE="$(boolean "${OMT_PRIVATE:-false}")"
HISTORY="$(boolean "${OMT_HISTORY:-false}")"
HISTORY_COMMIT="$(boolean "${OMT_HISTORY_COMMIT:-false}")"
if [[ "$HISTORY_COMMIT" == true && "$HISTORY" != true ]]; then
	echo '::error::history-commit requires history: true.'
	exit 1
fi
if [[ "$PRIVATE" == false && "$HISTORY" == false ]]; then
	export OCTOMAILTEST_WRAPPED=1
	exec bash "$ACTION_PATH/action/run.sh"
fi

# shellcheck source=lib/privacy.sh
source "$ACTION_PATH/lib/privacy.sh"
ALIAS="${OMT_ALIAS:-OctoMailTest}"
omt_privacy_validate_alias "$ALIAS" || { echo '::error::OctoMailTest alias is invalid.'; exit 1; }

umask 077
TEMP_DIR="$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/octomailtest-output.XXXXXX")"
trap 'rm -rf -- "$TEMP_DIR"' EXIT
OUTPUT_FILE="${GITHUB_OUTPUT:-}"
REPORT_DIR="${OMT_REPORT_DIR:-octomailtest-report}"
ARTIFACT_NAME="${OMT_ARTIFACT_NAME:-octomailtest-report}"
DOMAIN="${OMT_DOMAIN:-${OCTOMAILTEST_DOMAIN:-}}"
HOST="${OMT_HOST:-${OCTOMAILTEST_HOST:-}}"
EMAIL="${OMT_EMAIL:-${OCTOMAILTEST_EMAIL:-}}"
PASS="${OMT_PASS:-${OCTOMAILTEST_PASS:-}}"

# Config files already execute as shell in the original diagnostics. Read their
# credentials in isolation so both config and input values can be anonymized.
CONFIG="${OMT_CONFIG_FILE:-./.octomailtest}"
CONFIG_ERROR=false
if [[ "$PRIVATE" == true && -f "$CONFIG" ]]; then
	if bash -e -c 'source "$1"; printf "%s\0" "${DOMAIN:-}" "${HOST:-}" "${EMAIL:-}" "${PASS:-}" >&3' \
		_ "$CONFIG" 3> "$TEMP_DIR/config.values" > "$TEMP_DIR/config.output" 2>&1; then
		CONFIG_VALUES=()
		while IFS= read -r -d '' value; do
			CONFIG_VALUES+=("$value")
		done < "$TEMP_DIR/config.values"
		export OMT_PRIVACY_CONFIG_DOMAIN="${CONFIG_VALUES[0]:-}"
		export OMT_PRIVACY_CONFIG_HOST="${CONFIG_VALUES[1]:-}"
		export OMT_PRIVACY_CONFIG_EMAIL="${CONFIG_VALUES[2]:-}"
		export OMT_PRIVACY_CONFIG_PASS="${CONFIG_VALUES[3]:-}"
		[[ ${#CONFIG_VALUES[@]} == 4 ]] || CONFIG_ERROR=true
	else
		CONFIG_ERROR=true
	fi
fi

filter() {
	if [[ "$PRIVATE" == true ]]; then
		omt_privacy_filter "$ALIAS" "$DOMAIN" "$HOST" "$EMAIL" "$PASS"
	else
		cat
	fi
}

# Report/artifact names are public metadata too. Keep ordinary configured
# names, but substitute an alias-only name when anonymization would change it.
if [[ "$PRIVATE" == true ]]; then
	if [[ "$(printf '%s\n' "$ARTIFACT_NAME" | filter)" != "$ARTIFACT_NAME" ]]; then
		ARTIFACT_NAME="octomailtest-${ALIAS}"
	fi
	if [[ "$(printf '%s\n' "$REPORT_DIR" | filter)" != "$REPORT_DIR" ]]; then
		REPORT_DIR="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/octomailtest-report-${ALIAS}"
	fi
	RUNNER_LABEL="${ALIAS} runner"
else
	RUNNER_LABEL="${RUNNER_NAME:-}"
fi
[[ "$REPORT_DIR" == /* ]] || REPORT_DIR="$(pwd -P)/$REPORT_DIR"
check_path="$REPORT_DIR"
while [[ "$check_path" != / ]]; do
	[[ ! -L "$check_path" ]] || { echo '::error::Report paths must not contain symlinks.'; exit 1; }
	check_path="$(dirname -- "$check_path")"
done
for report_file in report.json report.txt summary.md; do
	[[ ! -L "$REPORT_DIR/$report_file" ]] || { echo '::error::Report files must not be symlinks.'; exit 1; }
done

# Prevent the standalone CLI hooks from recording a second run. The engine
# writes raw files only into this restricted, temporary directory. Its output
# crosses the privacy filter before reaching the Actions log.
if [[ "$CONFIG_ERROR" == true ]]; then
	echo "::error::${ALIAS}: configuration could not be inspected safely."
	RESULTS=(1 0)
else
	set +e
	OMT_REPORT_DIR="$TEMP_DIR/raw" GITHUB_OUTPUT="$TEMP_DIR/outputs" \
		RUNNER_NAME="$RUNNER_LABEL" OCTOMAILTEST_WRAPPED=1 bash "$ACTION_PATH/action/run.sh" 2>&1 | filter
	RESULTS=("${PIPESTATUS[@]}")
	set -e
fi
RUNNER_RC="${RESULTS[0]}"
if (( RESULTS[1] != 0 )); then
	echo "::error::${ALIAS}: output anonymization failed."
	exit 1
fi

mkdir -p -- "$REPORT_DIR"
if (( RUNNER_RC == 0 )) && [[ -s "$TEMP_DIR/raw/report.json" ]]; then
	if [[ "$PRIVATE" == true ]]; then
		omt_privacy_json "$ALIAS" "$DOMAIN" "$HOST" "$EMAIL" "$PASS" \
			< "$TEMP_DIR/raw/report.json" > "$TEMP_DIR/report.json"
		filter < "$TEMP_DIR/raw/report.txt" > "$TEMP_DIR/report.txt"
		filter < "$TEMP_DIR/raw/summary.md" > "$TEMP_DIR/summary.md"
	else
		cp "$TEMP_DIR/raw/report.json" "$TEMP_DIR/report.json"
		cp "$TEMP_DIR/raw/report.txt" "$TEMP_DIR/report.txt"
		cp "$TEMP_DIR/raw/summary.md" "$TEMP_DIR/summary.md"
	fi
	jq --arg alias "$ALIAS" --argjson private "$PRIVATE" \
		'. + {alias: $alias, private: $private}' "$TEMP_DIR/report.json" > "$REPORT_DIR/report.json"
	cp "$TEMP_DIR/report.txt" "$REPORT_DIR/report.txt"
	cp "$TEMP_DIR/summary.md" "$REPORT_DIR/summary.md"
else
	# Configuration/runner errors still produce a failed history entry. Never
	# include raw error text when the normal report could not be completed.
	jq -n --arg alias "$ALIAS" --argjson private "$PRIVATE" --argjson code "$RUNNER_RC" \
		--arg finished "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
		'{alias:$alias,private:$private,status:"failed",exit_code:(if $code == 0 then 1 else $code end),
		 failures:1,warnings:0,finished_at:$finished,output:"Diagnostic runner did not complete."}' > "$REPORT_DIR/report.json"
	printf '%s: FAIL — diagnostic runner did not complete.\n' "$ALIAS" > "$REPORT_DIR/report.txt"
	cp "$REPORT_DIR/report.txt" "$REPORT_DIR/summary.md"
fi

output() {
	[[ -n "$OUTPUT_FILE" ]] || return 0
	printf '%s=%s\n' "$1" "$2" >> "$OUTPUT_FILE"
}

for name in status failures warnings; do
	output "$name" "$(jq -r ".$name" "$REPORT_DIR/report.json")"
done
output exit-code "$(jq -r .exit_code "$REPORT_DIR/report.json")"
output report-dir "$REPORT_DIR"
output report-file "$REPORT_DIR/report.txt"
output report-json "$REPORT_DIR/report.json"
output summary-file "$REPORT_DIR/summary.md"
output artifact-name "$ARTIFACT_NAME"
output upload-artifact "$(boolean "${OMT_UPLOAD_ARTIFACT:-true}")"
output step-summary "$(boolean "${OMT_STEP_SUMMARY:-true}")"
output fail-on-error "$(boolean "${OMT_FAIL_ON_ERROR:-true}")"
output retention-days "${OMT_RETENTION_DAYS:-}"

if [[ "$HISTORY" == true ]]; then
	# shellcheck source=lib/history.sh
	source "$ACTION_PATH/lib/history.sh"
	HISTORY_ROOT="$(pwd -P)"
	if [[ "$HISTORY_COMMIT" == true ]]; then
		HISTORY_ROOT="${GITHUB_WORKSPACE:?}/.octomailtest-history-repository"
	fi
	omt_history_record "$ALIAS" "${OMT_HISTORY_DIR:-octomailtest-history}" "${OMT_HISTORY_KEEP:-10}" \
		"$REPORT_DIR/report.json" "$REPORT_DIR/report.txt" "$REPORT_DIR/summary.md" "$HISTORY_ROOT"
	output history-dir "$OMT_HISTORY_DIR"
	output history-index "$OMT_HISTORY_INDEX"
	output history-count "$OMT_HISTORY_COUNT"
fi
