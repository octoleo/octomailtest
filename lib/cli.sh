#!/usr/bin/env bash
# Opt-in CLI presentation/history. Diagnostic bodies execute unchanged.

omt_cli_error() {
	printf '%s\n' 'OctoMailTest: invalid privacy/history configuration or output failure.' >&2
	return 1
}

omt_cli_bool() {
	case "${1:-false}" in
		true|yes|on|1) printf true ;;
		false|no|off|0|'') printf false ;;
		*) return 1 ;;
	esac
}

# Resolve the existing config/env/CLI precedence without exposing config data.
omt_cli_values() (
	local kind="$1"
	shift
	DOMAIN='' HOST='' EMAIL='' PASS=''
	if [[ -f ./.octomailtest ]]; then
		# shellcheck disable=SC1091
		source ./.octomailtest >/dev/null 2>&1
	fi
	local config_domain="${DOMAIN:-}" config_host="${HOST:-}" config_email="${EMAIL:-}" config_pass="${PASS:-}"
	DOMAIN="${OCTOMAILTEST_DOMAIN:-${DOMAIN:-}}"
	HOST="${OCTOMAILTEST_HOST:-${HOST:-}}"
	EMAIL="${OCTOMAILTEST_EMAIL:-${EMAIL:-}}"
	PASS="${OCTOMAILTEST_PASS:-${PASS:-}}"
	if [[ "$kind" == diagnostic ]]; then
		while (( $# )); do
			case "$1" in
				-d|--domain) DOMAIN="${2:-}"; (( $# > 1 )) || break; shift 2 ;;
				-h|--host) HOST="${2:-}"; (( $# > 1 )) || break; shift 2 ;;
				-e|--email) EMAIL="${2:-}"; (( $# > 1 )) || break; shift 2 ;;
				-p|--pass) PASS="${2:-}"; (( $# > 1 )) || break; shift 2 ;;
				-c|--config)
					if [[ -n "${2:-}" && -f "$2" ]]; then
						# shellcheck disable=SC1090
						source "$2" >/dev/null 2>&1
					fi
					(( $# > 1 )) || break
					shift 2
					;;
				*) shift ;;
			esac
		done
	fi
	printf '%s\0' "${DOMAIN:-}" "${HOST:-}" "${EMAIL:-}" "${PASS:-}" "$config_domain" "$config_host" "$config_email" "$config_pass"
)

omt_cli_dispatch() {
	local kind="$1" script="$2"
	shift 2
	[[ "${OCTOMAILTEST_WRAPPED:-}" != 1 ]] || return 0
	local enabled=false arg
	for arg in "$@"; do
		case "$arg" in
			--private|--alias|--history|--history-keep|--history-dir) enabled=true ;;
		esac
	done
	[[ -z "${OCTOMAILTEST_PRIVATE:-}${OCTOMAILTEST_ALIAS:-}${OCTOMAILTEST_HISTORY:-}${OCTOMAILTEST_HISTORY_KEEP:-}${OCTOMAILTEST_HISTORY_DIR:-}" ]] || enabled=true
	[[ "$enabled" == true ]] || return 0
	omt_cli_execute "$kind" "$script" "$@"
	exit "$?"
}

omt_cli_execute() (
	set +x
	umask 077
	local kind="$1" script="$2"
	shift 2
	local private history alias keep directory format=text log_file='' mode
	private="$(omt_cli_bool "${OCTOMAILTEST_PRIVATE:-false}")" || { omt_cli_error; exit 1; }
	history="$(omt_cli_bool "${OCTOMAILTEST_HISTORY:-false}")" || { omt_cli_error; exit 1; }
	alias="${OCTOMAILTEST_ALIAS:-OctoMailTest}"
	keep="${OCTOMAILTEST_HISTORY_KEEP:-10}"
	directory="${OCTOMAILTEST_HISTORY_DIR:-octomailtest-history}"
	local args=() help=false
	if [[ "$kind" == docker ]]; then log_file="${OCTOMAILTEST_LOG:-}"; fi
	while (( $# )); do
		case "$1" in
			--private) private=true; shift ;;
			--history) history=true; shift ;;
			--alias|--history-keep|--history-dir)
				(( $# > 1 )) || { omt_cli_error; exit 1; }
				case "$1" in
					--alias) alias="$2" ;;
					--history-keep) keep="$2" ;;
					--history-dir) directory="$2" ;;
				esac
				shift 2
				;;
			--json)
				if [[ "$kind" == docker ]]; then format=json; fi
				args+=("$1")
				shift
				;;
			-L|--log)
				if [[ "$kind" == docker ]]; then
					(( $# > 1 )) || { omt_cli_error; exit 1; }
					log_file="$2"; shift 2
				else args+=("$1"); shift; fi
				;;
			--help) help=true; args+=("$1"); shift ;;
			-d|--domain|-h|--host|-e|--email|-p|--pass|-c|--config|--imap-port|--smtp-port|--sieve-port)
				args+=("$1")
				shift
				if (( $# )); then args+=("$1"); shift; fi
				;;
			*) args+=("$1"); shift ;;
		esac
	done

	local library
	library="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)" || exit 1
	# shellcheck disable=SC1091
	source "${library}/privacy.sh"
	omt_privacy_validate_alias "$alias" || { omt_cli_error; exit 1; }
	[[ "$keep" =~ ^[1-9][0-9]*$ ]] || { omt_cli_error; exit 1; }
	if [[ "$history" == true || "$format" == json ]]; then
		command -v jq >/dev/null 2>&1 || { omt_cli_error; exit 1; }
	fi

	local temp
	temp="$(mktemp -d "${TMPDIR:-/tmp}/octomailtest-cli.XXXXXX" 2>/dev/null)" || { omt_cli_error; exit 1; }
	trap 'rm -rf -- "$temp"' EXIT
	local domain host email pass
	local OMT_PRIVACY_CONFIG_DOMAIN OMT_PRIVACY_CONFIG_HOST OMT_PRIVACY_CONFIG_EMAIL OMT_PRIVACY_CONFIG_PASS
	if ! omt_cli_values "$kind" "${args[@]}" > "$temp/values" 2>/dev/null; then
		omt_cli_error; exit 1
	fi
	{
		IFS= read -r -d '' domain
		IFS= read -r -d '' host
		IFS= read -r -d '' email
		IFS= read -r -d '' pass
		IFS= read -r -d '' OMT_PRIVACY_CONFIG_DOMAIN
		IFS= read -r -d '' OMT_PRIVACY_CONFIG_HOST
		IFS= read -r -d '' OMT_PRIVACY_CONFIG_EMAIL
		IFS= read -r -d '' OMT_PRIVACY_CONFIG_PASS
	} < "$temp/values"
	export OMT_PRIVACY_CONFIG_DOMAIN OMT_PRIVACY_CONFIG_HOST OMT_PRIVACY_CONFIG_EMAIL OMT_PRIVACY_CONFIG_PASS
	rm -f -- "$temp/values"

	local filter=(cat) sink=(tee "$temp/report.txt")
	if [[ "$private" == true ]]; then
		filter=(omt_privacy_filter "$alias" "$domain" "$host" "$email" "$pass")
	fi
	if [[ -n "$log_file" ]]; then
		mkdir -p -- "$(dirname -- "$log_file")" 2>/dev/null || { omt_cli_error; exit 1; }
		sink=(tee -a "$log_file" "$temp/report.txt")
	fi
	local started finished rc codes
	started="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
	set +e
	if [[ "$format" == json ]]; then
		# Keep the original JSON branch and its exact command ordering/status.
		# Its raw JSON/stderr stay in the private temporary directory until
		# sanitized; only processed text is copied to the requested log file.
		if [[ -n "$log_file" ]]; then args+=(--log "$temp/child.log"); fi
		OCTOMAILTEST_WRAPPED=1 OCTOMAILTEST_LOG='' bash "$script" "${args[@]}" \
			> "$temp/raw.json" 2> "$temp/raw.stderr"
		codes=("$?" 0 0)
	else
		OCTOMAILTEST_WRAPPED=1 OCTOMAILTEST_LOG='' bash "$script" "${args[@]}" 2>&1 \
			| "${filter[@]}" | "${sink[@]}" 2>/dev/null
		codes=("${PIPESTATUS[@]}")
	fi
	set -e
	rc="${codes[0]}"
	if (( codes[1] != 0 || codes[2] != 0 )); then omt_cli_error; exit 1; fi
	if [[ "$format" == json ]]; then
		"${filter[@]}" < "$temp/raw.stderr" > "$temp/stderr.txt" || { omt_cli_error; exit 1; }
		cat "$temp/stderr.txt" >&2
		if [[ "$help" == true ]]; then
			"${filter[@]}" < "$temp/raw.json" || { omt_cli_error; exit 1; }
		elif jq -e 'type == "object" and (.output | type == "string")' "$temp/raw.json" >/dev/null 2>&1; then
			if [[ "$private" == true ]]; then
				omt_privacy_json "$alias" "$domain" "$host" "$email" "$pass" < "$temp/raw.json" > "$temp/sanitized.json" || { omt_cli_error; exit 1; }
			else
				cp "$temp/raw.json" "$temp/sanitized.json"
			fi
			jq -r .output "$temp/sanitized.json" > "$temp/report.txt"
			cat "$temp/stderr.txt" >> "$temp/report.txt"
		else
			"${filter[@]}" < "$temp/raw.json" > "$temp/report.txt" || { omt_cli_error; exit 1; }
			cat "$temp/stderr.txt" >> "$temp/report.txt"
			(( rc != 0 )) || rc=1
		fi
		if [[ -n "$log_file" && "$help" != true ]]; then
			cat "$temp/report.txt" >> "$log_file" 2>/dev/null || { omt_cli_error; exit 1; }
		fi
	fi
	finished="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
	if [[ "$help" == true ]]; then
		printf '\nPrivacy/history: --private --alias NAME --history --history-keep N --history-dir PATH\n'
		exit "$rc"
	fi
	mode="$(basename -- "$script")"
	if [[ "$kind" == docker ]]; then
		case "${args[0]:-both}" in mail|imap|both) mode="${args[0]:-both}" ;; *) mode=both ;; esac
	fi
	local status=passed failures warnings
	(( rc == 0 )) || status=failed
	if [[ "$history" == true || "$format" == json ]]; then
		failures="$(grep -F '❌' "$temp/report.txt" | grep -vcF 'Critical failures:' || true)"
		warnings="$(grep -cF '⚠️' "$temp/report.txt" || true)"
		jq -n --arg alias "$alias" --arg action "$mode" --arg status "$status" \
			--arg started_at "$started" --arg finished_at "$finished" \
			--argjson exit_code "$rc" --argjson private "$private" \
			--argjson failures "$failures" --argjson warnings "$warnings" \
			--rawfile output "$temp/report.txt" \
			'{alias:$alias,action:$action,status:$status,exit_code:$exit_code,private:$private,
			  started_at:$started_at,finished_at:$finished_at,failures:$failures,warnings:$warnings,output:$output}' \
			> "$temp/report.json"
		{
			printf '# %s: %s\n\n' "$alias" "$status"
			printf 'Completed: %s\n\n```text\n' "$finished"
			cat "$temp/report.txt"
			printf '\n```\n'
		} > "$temp/summary.md"
	fi
	if [[ "$history" == true ]]; then
		# shellcheck disable=SC1091
		source "${library}/history.sh"
		omt_history_record "$alias" "$directory" "$keep" "$temp/report.json" "$temp/report.txt" "$temp/summary.md" "$PWD" || exit 1
	fi
	if [[ "$format" == json ]]; then cat "$temp/report.json"; fi
	exit "$rc"
)
