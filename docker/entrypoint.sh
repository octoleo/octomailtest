#!/usr/bin/env bash
set -euo pipefail

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
			mail) run "/app/mail" ;;
			imap) run "/app/imap" ;;
			both)
				run "/app/mail"
				run "/app/imap"
				;;
		esac
	)

	jq -n --arg action "$ACTION" --arg output "$OUTPUT" \
		'{ action: $action, output: $output }'
else
	case "$ACTION" in
		mail)
			run "/app/mail"
			;;
		imap)
			run "/app/imap"
			;;
		both)
			run "/app/mail"
			echo "----------------------------------------"
			run "/app/imap"
			;;
	esac
fi
