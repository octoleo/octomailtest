#!/usr/bin/env bash
# Retained per-alias history. Callers supply reports after privacy filtering.

omt_history_error() { printf 'OctoMailTest history: %s\n' "$1" >&2; }

omt_history_alias_valid() {
	[[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$ ]]
}

# Resolve a directory below a trusted root, without traversing symlinks.
omt_history_resolve_dir() {
	local root="$1" relative="$2" create="${3:-false}" component current
	local -a components
	[[ -n "$relative" && "$relative" != /* && "$relative" != */ && "$relative" != *//* && "$relative" != *$'\n'* && "$relative" != *$'\r'* ]] || {
		omt_history_error 'Use a safe relative history directory.'; return 1;
	}
	root="$(cd "$root" 2>/dev/null && pwd -P)" || {
		omt_history_error 'The repository directory does not exist.'; return 1;
	}
	IFS=/ read -r -a components <<< "$relative"
	current="$root"
	for component in "${components[@]}"; do
		[[ -n "$component" && "$component" != . && "$component" != .. && "$component" != .git ]] || {
			omt_history_error 'History cannot use parent traversal or Git administrative paths.'; return 1;
		}
		current="${current}/${component}"
		[[ ! -L "$current" && ( ! -e "$current" || -d "$current" ) ]] || {
			omt_history_error 'History cannot use symlinks or non-directory components.'; return 1;
		}
		if [[ "$create" == true && ! -d "$current" ]]; then
			if ! mkdir "$current" 2>/dev/null && [[ ! -d "$current" || -L "$current" ]]; then
				omt_history_error 'Cannot create the history directory.'; return 1
			fi
		fi
	done
	printf '%s\n' "$current"
}

# Only generated files belong to this feature; never replace arbitrary files.
omt_history_tree_valid() (
	local directory="$1" path run file name
	shopt -s nullglob dotglob
	[[ -d "$directory" && ! -L "$directory" ]] || return 1
	for path in "$directory"/*; do
		[[ ! -L "$path" ]] || return 1
		case "${path##*/}" in
			history.json|README.md) [[ -f "$path" ]] || return 1 ;;
			runs)
				[[ -d "$path" ]] || return 1
				for run in "$path"/*; do
					[[ ! -L "$run" && -d "$run" && "${run##*/}" =~ ^[1-9][0-9]*$ ]] || return 1
					for file in "$run"/*; do
						name="${file##*/}"
						[[ ! -L "$file" && -f "$file" && ( "$name" == report.json || "$name" == report.txt || "$name" == summary.md ) ]] || return 1
					done
				done
				;;
			*) return 1 ;;
		esac
	done
)

omt_history_state_valid() {
	local state="$1" alias="$2" private="$3"
	jq -e --arg alias "$alias" --argjson private "$private" '
		def uint: type == "number" and . >= 0 and . <= 9007199254740990 and floor == .;
		. as $state | .schema_version == 1 and .alias == $alias and .private == $private
		and (.total_runs | uint) and (.passed_runs | uint) and (.failed_runs | uint)
		and .total_runs == (.passed_runs + .failed_runs)
		and (.runs | type == "array") and (.runs | length) <= .total_runs
		and (if .total_runs == 0 then (.runs | length) == 0 else (.runs | length) > 0 end)
		and ([.runs[].number] == ([.runs[].number] | unique | reverse))
		and all(.runs[]; (.number | uint) and .number > 0 and .number <= $state.total_runs
			and (.status == "passed" or .status == "failed")
			and (.timestamp | type == "string")
			and (.timestamp | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
			and (.exit_code | uint) and (.failures | uint) and (.warnings | uint))
	' "$state" >/dev/null 2>&1
}

# omt_history_record <alias> <relative base dir> <keep> <report.json>
#                    <report.txt> <summary.md> [repository root]
# Sets OMT_HISTORY_DIR, OMT_HISTORY_INDEX and OMT_HISTORY_COUNT on success.
omt_history_record() {
	local alias="$1" base="$2" keep="$3" json="$4" report="$5" summary="$6" root="${7:-$PWD}"
	local directory private file
	command -v jq >/dev/null 2>&1 || { omt_history_error 'jq is required.'; return 1; }
	omt_history_alias_valid "$alias" || { omt_history_error 'Use a public alias of 1-64 letters, digits, underscores or hyphens, starting with a letter or digit.'; return 1; }
	if [[ ! "$keep" =~ ^[1-9][0-9]*$ ]] || ! jq -en --arg value "$keep" '$value | tonumber | . <= 2147483647' >/dev/null 2>&1; then
		omt_history_error 'History retention must be a positive integer.'; return 1
	fi
	for file in "$json" "$report" "$summary"; do
		[[ -f "$file" && ! -L "$file" ]] || { omt_history_error 'A complete report is required before recording history.'; return 1; }
	done
	jq -e '
		def uint: type == "number" and . >= 0 and floor == .;
		(.status == "passed" or .status == "failed") and (.exit_code | uint)
		and ((.failures // 0) | uint) and ((.warnings // 0) | uint)
		and ((.private // false) | type == "boolean")
	' "$json" >/dev/null 2>&1 || { omt_history_error 'The report result is invalid.'; return 1; }
	private="$(jq -r '.private // false' "$json")" || return 1
	directory="$(omt_history_resolve_dir "$root" "$base" true)" || return 1
	directory="${directory}/${alias}"
	_omt_history_record "$directory" "$alias" "$keep" "$json" "$report" "$summary" "$private" || return 1
	# Public return values for the sourcing caller.
	# shellcheck disable=SC2034
	OMT_HISTORY_DIR="$directory"
	# shellcheck disable=SC2034
	OMT_HISTORY_INDEX="${directory}/README.md"
	# shellcheck disable=SC2034
	OMT_HISTORY_COUNT="$(jq -r '.total_runs' "${directory}/history.json")" || return 1
}

_omt_history_record() (
	umask 077
	local directory="$1" alias="$2" keep="$3" json="$4" report="$5" summary="$6" private="$7"
	local parent="${directory%/*}" lock="${directory}.lock" stage='' backup='' number timestamp state run file
	mkdir "$lock" 2>/dev/null || { omt_history_error 'This alias history is locked by another run; serialize runs for the same alias.'; return 1; }
	# Invoked through the EXIT trap; preserve the previous history if restoration fails.
	# shellcheck disable=SC2317
	cleanup() {
		if [[ -n "$backup" && -d "$backup" && ! -e "$directory" ]]; then
			mv "$backup" "$directory" 2>/dev/null || {
				omt_history_error 'Could not restore the previous history; its backup was preserved.'
				backup=''
			}
		fi
		[[ -z "$stage" || ! -d "$stage" ]] || rm -rf -- "$stage"
		[[ -z "$backup" || ! -d "$backup" ]] || rm -rf -- "$backup"
		rmdir "$lock" 2>/dev/null || true
	}
	trap cleanup EXIT
	trap 'exit 130' INT
	trap 'exit 143' TERM
	[[ ! -L "$directory" && ( ! -e "$directory" || -d "$directory" ) ]] || {
		omt_history_error 'The alias history must be a directory and cannot be a symlink.'; return 1;
	}
	stage="$(mktemp -d "${parent}/.history-stage.XXXXXX")" || return 1
	state="${stage}/history.json"
	if [[ -d "$directory" ]]; then
		omt_history_tree_valid "$directory" || { omt_history_error 'The history directory contains files not owned by OctoMailTest.'; return 1; }
		[[ -f "${directory}/history.json" ]] || { omt_history_error 'Existing history is missing its counter; refusing to reset it.'; return 1; }
		omt_history_state_valid "${directory}/history.json" "$alias" "$private" || {
			omt_history_error 'History is invalid or its privacy mode changed; use a new directory instead of resetting or mixing reports.'; return 1;
		}
		cp "${directory}/history.json" "$state" || return 1
	else
		jq -n --arg alias "$alias" --argjson private "$private" '{schema_version:1, alias:$alias, private:$private, total_runs:0, passed_runs:0, failed_runs:0, runs:[]}' > "$state" || return 1
	fi
	number="$(jq -r '.total_runs + 1' "$state")" || return 1
	timestamp="$(date -u +%Y-%m-%dT%H:%M:%SZ)" || return 1
	jq --arg timestamp "$timestamp" --argjson keep "$keep" --slurpfile report "$json" '
		($report[0]) as $report |
		.total_runs += 1 |
		if $report.status == "passed" then .passed_runs += 1 else .failed_runs += 1 end |
		.runs = ([{number:.total_runs, timestamp:$timestamp, status:$report.status,
			exit_code:$report.exit_code, failures:($report.failures // 0), warnings:($report.warnings // 0)}] + .runs)[:$keep]
	' "$state" > "${stage}/next.json" || return 1
	mv "${stage}/next.json" "$state" || return 1
	mkdir "${stage}/runs" || return 1
	while IFS= read -r run; do
		mkdir "${stage}/runs/${run}" || return 1
		if [[ "$run" == "$number" ]]; then
			cp "$json" "${stage}/runs/${run}/report.json" || return 1
			cp "$report" "${stage}/runs/${run}/report.txt" || return 1
			cp "$summary" "${stage}/runs/${run}/summary.md" || return 1
		else
			for file in report.json report.txt summary.md; do
				[[ -f "${directory}/runs/${run}/${file}" && ! -L "${directory}/runs/${run}/${file}" ]] || {
					omt_history_error 'A retained report is missing; refusing to discard history.'; return 1;
				}
				cp "${directory}/runs/${run}/${file}" "${stage}/runs/${run}/${file}" || return 1
			done
		fi
	done < <(jq -r '.runs[].number' "$state")
	{
		printf '# %s test history\n\n' "$alias"
		jq -r '"Total runs: **\(.total_runs)** · Passed: **\(.passed_runs)** · Failed: **\(.failed_runs)**\n"' "$state"
		printf 'Showing the most recent %s runs. Counters include all recorded runs. Timestamps are UTC.\n\n' "$keep"
		printf '| Run | Timestamp (UTC) | Result | Failures | Warnings | Findings |\n|---|---|---|---|---|---|\n'
		jq -r '.runs[] | "| \(.number) | \(.timestamp) | \(.status | ascii_upcase) | \(.failures) | \(.warnings) | [Summary](runs/\(.number)/summary.md) · [Text](runs/\(.number)/report.txt) · [JSON](runs/\(.number)/report.json) |"' "$state"
		printf '\n[Machine-readable history](history.json)\n'
	} > "${stage}/README.md" || return 1
	if [[ -d "$directory" ]]; then
		backup="$(mktemp -d "${parent}/.history-backup.XXXXXX")" || return 1
		rmdir "$backup" || return 1
		mv "$directory" "$backup" || return 1
	fi
	mv "$stage" "$directory" || return 1
	stage=''
	if [[ -n "$backup" ]]; then rm -rf -- "$backup" || return 1; backup=''; fi
)
