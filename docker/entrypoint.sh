#!/usr/bin/env bash
set -euo pipefail

# Handle opt-in output/history features outside the existing test cycle.
if [[ "${OCTOMAILTEST_WRAPPED:-}" != 1 ]]; then
	_omt_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
	[[ -f "${_omt_dir}/lib/cli.sh" ]] || _omt_dir="${_omt_dir}/.."
	if [[ -f "${_omt_dir}/lib/cli.sh" ]]; then
		# shellcheck disable=SC1091
		source "${_omt_dir}/lib/cli.sh"
		omt_cli_dispatch docker "$0" "$@"
	else
		_omt_required="${OCTOMAILTEST_PRIVATE:-}${OCTOMAILTEST_ALIAS:-}${OCTOMAILTEST_HISTORY:-}${OCTOMAILTEST_HISTORY_KEEP:-}${OCTOMAILTEST_HISTORY_DIR:-}"
		for _omt_arg in "$@"; do
			case "$_omt_arg" in --private|--alias|--history|--history-keep|--history-dir) _omt_required=1 ;; esac
		done
		if [[ -n "$_omt_required" ]]; then
			printf '%s\n' 'OctoMailTest: privacy/history requires the accompanying lib directory.' >&2
			exit 1
		fi
	fi
fi

#############################################
# Defaults
#############################################
ACTION="both"
LOG_FILE="${OCTOMAILTEST_LOG:-}"
MODE="normal"   # normal | ci
FORMAT="text"   # text | json

#############################################
# Parse command (optional)
#############################################
if [[ $# -gt 0 ]]; then
	case "$1" in
		mail|imap|both)
			ACTION="$1"
			shift
			;;
	esac
fi

#############################################
# Parse flags
#############################################
while [[ $# -gt 0 ]]; do
	case "$1" in
		-L|--log)
			LOG_FILE="$2"
			shift 2
			;;
		--ci|--quiet)
			MODE="ci"
			shift
			;;
		--json)
			FORMAT="json"
			shift
			;;
		--help)
			cat <<EOF
Usage: octomailtest [mail|imap|both] [options]

Default command:
  both

Options:
  --ci, --quiet    Suppress banners and separators
  --json           Emit JSON output (CI-friendly)
  -L, --log FILE   Write output to FILE (also stdout)
  --private       Anonymize identifiers while retaining test details
  --alias NAME    Public system label (default: OctoMailTest)
  --history       Keep timestamped findings and a cumulative run count
  --history-keep N Retained runs (default: 10)
  --history-dir PATH History directory (default: octomailtest-history)

Environment:
  OCTOMAILTEST_*   Passed directly to scripts
EOF
			exit 0
			;;
		*)
			echo "Unknown option: $1" >&2
			exit 1
			;;
	esac
done

#############################################
# Runner
#############################################

run() {
	local cmd="$1"
	if [[ "$MODE" == "ci" ]]; then
		cmd="$cmd | sed '/^=====/d'"
	fi

	if [[ -n "$LOG_FILE" ]]; then
		mkdir -p "$(dirname "$LOG_FILE")"
		eval "$cmd" 2>&1 | tee -a "$LOG_FILE"
	else
		eval "$cmd"
	fi
}

#############################################
# Execute + format
#############################################
if [[ "$FORMAT" == "json" ]]; then
	OUTPUT=$(
		case "$ACTION" in
			mail) run "./mail" ;;
			imap) run "./imap" ;;
			both)
				run "./mail"
				run "./imap"
				;;
		esac
	)

	jq -n --arg action "$ACTION" --arg output "$OUTPUT" \
		'{ action: $action, output: $output }'
else
	case "$ACTION" in
		mail)
			run "./mail"
			;;
		imap)
			run "./imap"
			;;
		both)
			run "./mail"
			echo "----------------------------------------"
			run "./imap"
			;;
	esac
fi
