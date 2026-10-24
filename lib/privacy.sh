#!/usr/bin/env bash
# Shared output anonymization. Source this file; it does not change shell options.
# Filter stdout AND stderr before tee, reports, annotations, or other public sinks.

omt_privacy_validate_alias() {
	[[ ${1:-} =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$ ]]
}

# omt_privacy_filter <alias> <domain> <host> <email> <password>
# Optional OMT_PRIVACY_CONFIG_{DOMAIN,HOST,EMAIL,PASS} also protect credentials
# loaded from a config file when they differ from the explicitly supplied values.
# All values reach awk through its environment, never through command-line args.
omt_privacy_filter() {
	local alias=${1:-OctoMailTest} domain=${2:-} host=${3:-} email=${4:-} password=${5:-}
	local password_b64 email_b64 auth_b64 password_shell config_b64 config_email_b64 config_auth config_shell
	local awk_options=()
	if ! omt_privacy_validate_alias "$alias"; then
		printf '%s\n' 'Invalid private alias: use 1-64 letters, digits, underscores or hyphens.' >&2
		return 2
	fi
	# mawk buffers pipe input even when every output line is flushed. Its
	# interactive mode reads complete lines as they arrive, so private logs
	# stay live while a diagnostic waits for a server response. GNU/BSD awk
	# already read this way. Never let this implementation probe read stdin.
	case "$(LC_ALL=C awk -W version </dev/null 2>&1)" in
		mawk*) awk_options=(-W interactive) ;;
	esac
	password_b64=$(printf '%s' "$password" | base64 | tr -d '\n') || return 1
	email_b64=$(printf '%s' "$email" | base64 | tr -d '\n') || return 1
	auth_b64=$(printf '\0%s\0%s' "$email" "$password" | base64 | tr -d '\n') || return 1
	config_b64=$(printf '%s' "${OMT_PRIVACY_CONFIG_PASS:-}" | base64 | tr -d '\n') || return 1
	config_email_b64=$(printf '%s' "${OMT_PRIVACY_CONFIG_EMAIL:-}" | base64 | tr -d '\n') || return 1
	config_auth=$(printf '\0%s\0%s' "${OMT_PRIVACY_CONFIG_EMAIL:-}" "${OMT_PRIVACY_CONFIG_PASS:-}" | base64 | tr -d '\n') || return 1
	printf -v password_shell '%q' "$password"
	printf -v config_shell '%q' "${OMT_PRIVACY_CONFIG_PASS:-}"
	OMT_PRIVATE_ALIAS="$alias" OMT_PRIVATE_DOMAIN="$domain" OMT_PRIVATE_HOST="$host" \
	OMT_PRIVATE_EMAIL="$email" OMT_PRIVATE_PASSWORD="$password" \
	OMT_PRIVATE_PASSWORD_B64="$password_b64" OMT_PRIVATE_EMAIL_B64="$email_b64" \
	OMT_PRIVATE_AUTH_B64="$auth_b64" OMT_PRIVATE_PASSWORD_SHELL="$password_shell" \
	OMT_PRIVATE_CONFIG_B64="$config_b64" OMT_PRIVATE_CONFIG_EMAIL_B64="$config_email_b64" OMT_PRIVATE_CONFIG_AUTH="$config_auth" \
	OMT_PRIVATE_CONFIG_SHELL="$config_shell" \
	OMT_PRIVACY_CONFIG_DOMAIN="${OMT_PRIVACY_CONFIG_DOMAIN:-}" OMT_PRIVACY_CONFIG_HOST="${OMT_PRIVACY_CONFIG_HOST:-}" \
	OMT_PRIVACY_CONFIG_EMAIL="${OMT_PRIVACY_CONFIG_EMAIL:-}" OMT_PRIVACY_CONFIG_PASS="${OMT_PRIVACY_CONFIG_PASS:-}" \
	LC_ALL=C awk ${awk_options[@]+"${awk_options[@]}"} '
	function token(label, id) {
		id = ++token_count
		labels[id] = "[" alias " " label "]"
		return sprintf("\036%d\037", id)
	}
	function literal(s, needle, replacement, insensitive, out, at, search) {
		if (needle == "") return s
		search = insensitive ? tolower(needle) : needle
		out = ""
		while (1) {
			at = index(insensitive ? tolower(s) : s, search)
			if (!at) return out s
			out = out substr(s, 1, at - 1) replacement
			s = substr(s, at + length(needle))
		}
	}
	function add_field(value, replacement, insensitive, boundary) {
		if (value == "") return
		field_count++
		field_value[field_count] = value; field_replacement[field_count] = replacement
		field_insensitive[field_count] = insensitive; field_boundary[field_count] = boundary
	}
	function field_position(s, j, search, needle, offset, at, before, after) {
		search = field_insensitive[j] ? tolower(s) : s
		needle = field_insensitive[j] ? tolower(field_value[j]) : field_value[j]
		offset = 1
		while ((at = index(substr(search, offset), needle))) {
			at += offset - 1
			before = at > 1 ? substr(s, at - 1, 1) : ""
			after = substr(s, at + length(needle), 1)
			if (!field_boundary[j] || (before !~ /[A-Za-z0-9_@.-]/ && after !~ /[A-Za-z0-9_@.-]/)) return at
			offset = at + length(needle)
		}
		return 0
	}
	function protect(s, out, j, at, best_at, best_field, best_length) {
		# Protect overlapping literals together, so a short password cannot
		# partially replace a longer host or encoded credential before masking it.
		out = ""
		while (length(s)) {
			best_at = 0; best_field = 0; best_length = 0
			for (j = 1; j <= field_count; j++) {
				at = field_position(s, j)
				if (at && (!best_at || at < best_at || (at == best_at && length(field_value[j]) > best_length))) {
					best_at = at; best_field = j; best_length = length(field_value[j])
				}
			}
			if (!best_at) return out s
			out = out substr(s, 1, best_at - 1) field_replacement[best_field]
			s = substr(s, best_at + best_length)
		}
		return out
	}
	function identifier(s, kind, key) {
		key = tolower(s); sub(/\.$/, "", key)
		if ((key == tolower(email) && email != "") || (key == tolower(config_email) && config_email != "")) return email_token
		if ((key == tolower(host) && host != "") || (key == tolower(config_host) && config_host != "")) return host_token
		if ((key == tolower(domain) && domain != "") || (key == tolower(config_domain) && config_domain != "")) return domain_token
		# Fixed public test services describe the check, not the target.
		if (key in public_services) return s
		if (kind == "email") {
			if (!(key in emails)) emails[key] = token("related email")
			return emails[key]
		}
		if (kind == "IP") {
			if (!(key in addresses)) addresses[key] = token("IP")
			return addresses[key]
		}
		if (!(key in hosts)) hosts[key] = token("related host")
		return hosts[key]
	}
	function pattern(s, regex, kind, out, at, n, value, replacement) {
		out = ""
		while (match(s, regex)) {
			at = RSTART; n = RLENGTH; value = substr(s, at, n)
			# Fixed report filenames are not target identities.
			if (kind == "IP" && dnsbl_response && value ~ /^127\./) replacement = value
			else if (kind == "host" && (value == "report.txt" || value == "report.json" || value == "summary.md" || value == "history.json" || value == "README.md")) replacement = value
			else replacement = identifier(value, kind)
			out = out substr(s, 1, at - 1) replacement
			s = substr(s, at + n)
		}
		return out s
	}
	function ipv6(s, out, at, n, value, check, colons, before, after) {
		out = ""
		while (match(s, /[[:xdigit:]:.]+(%[[:alnum:]_.-]+)?/)) {
			at = RSTART; n = RLENGTH; value = substr(s, at, n)
			check = value; colons = gsub(/:/, ":", check)
			before = at > 1 ? substr(s, at - 1, 1) : ""
			after = substr(s, at + n, 1)
			# Boundaries prevent ::error::, ::group::, etc. from being mistaken
			# for compressed IPv6; their message bodies still pass through here.
			if ((index(value, "::") || colons >= 7) && value !~ /:::/ && before !~ /[[:alnum:]_-]/ && after !~ /[[:alnum:]_-]/) value = identifier(value, "IP")
			out = out substr(s, 1, at - 1) value
			s = substr(s, at + n)
		}
		return out s
	}
	function keys(s, out, at, n, value, eq, key, payload, replacement, dkim) {
		out = ""
		dkim = (s ~ /v=DKIM1/)
		while (match(s, /(^|[;[:space:]\"])(p|b|bh)[[:space:]]*=[^;]+/)) {
			at = RSTART; n = RLENGTH; value = substr(s, at, n); eq = index(value, "=")
			key = substr(value, 1, eq - 1); gsub(/^[;[:space:]\"]+|[[:space:]]+$/, "", key)
			payload = substr(value, eq + 1); gsub(/[[:space:]\"]/, "", payload)
			# DMARC p=none/quarantine/reject is useful policy data, not a key.
			if (payload != "" && (key != "p" || dkim || (length(payload) > 32 && payload ~ /^[A-Za-z0-9+\/=]+$/))) replacement = substr(value, 1, eq) secret_token
			else replacement = value
			out = out substr(s, 1, at - 1) replacement
			s = substr(s, at + n)
		}
		return out s
	}
	function add_secret(s, parts, j, lines) {
		if (s == "") return
		secrets[++secret_count] = s
		parts = split(s, lines, /[\r\n]+/)
		for (j = 1; j <= parts; j++) if (lines[j] != "" && lines[j] != s) secrets[++secret_count] = lines[j]
	}
	function restore(s, j) {
		for (j = 1; j <= token_count; j++) s = literal(s, sprintf("\036%d\037", j), labels[j], 0)
		return s
	}
	BEGIN {
		alias = ENVIRON["OMT_PRIVATE_ALIAS"]
		domain = ENVIRON["OMT_PRIVATE_DOMAIN"]; host = ENVIRON["OMT_PRIVATE_HOST"]; email = ENVIRON["OMT_PRIVATE_EMAIL"]
		config_domain = ENVIRON["OMT_PRIVACY_CONFIG_DOMAIN"]; config_host = ENVIRON["OMT_PRIVACY_CONFIG_HOST"]; config_email = ENVIRON["OMT_PRIVACY_CONFIG_EMAIL"]
		domain_token = token("domain"); host_token = token("host"); email_token = token("email"); secret_token = token("redacted")
		workflow_delimiter = sprintf("\036%d\037", ++token_count); labels[token_count] = "::"
		public_services["zen.spamhaus.org"] = 1; public_services["bl.spamcop.net"] = 1
		public_services["b.barracudacentral.org"] = 1; public_services["dnsbl.sorbs.net"] = 1
		public_services["github.com"] = 1; public_services["api.github.com"] = 1
		if (ENVIRON["OMT_PRIVATE_PASSWORD"] != "") {
			add_secret(ENVIRON["OMT_PRIVATE_PASSWORD"]); add_secret(ENVIRON["OMT_PRIVATE_PASSWORD_B64"])
			add_secret(ENVIRON["OMT_PRIVATE_AUTH_B64"]); add_secret(ENVIRON["OMT_PRIVATE_PASSWORD_SHELL"])
		}
		if (ENVIRON["OMT_PRIVACY_CONFIG_PASS"] != "") {
			add_secret(ENVIRON["OMT_PRIVACY_CONFIG_PASS"]); add_secret(ENVIRON["OMT_PRIVATE_CONFIG_B64"])
			add_secret(ENVIRON["OMT_PRIVATE_CONFIG_AUTH"]); add_secret(ENVIRON["OMT_PRIVATE_CONFIG_SHELL"])
		}
		if (email != "") add_secret(ENVIRON["OMT_PRIVATE_EMAIL_B64"])
		if (config_email != "") add_secret(ENVIRON["OMT_PRIVATE_CONFIG_EMAIL_B64"])
		for (i = 1; i <= secret_count; i++) add_field(secrets[i], secret_token, 0, 0)
		add_field(email, email_token, 1, 1); add_field(host, host_token, 1, 1); add_field(domain, domain_token, 1, 1)
		add_field(config_email, email_token, 1, 1); add_field(config_host, host_token, 1, 1); add_field(config_domain, domain_token, 1, 1)
	}
	{
		line = $0
		gsub(/\033\[[0-9;]*[[:alpha:]]/, "", line)
		gsub(/[\001-\010\013-\037\177]/, "", line)
		# Reserve only the envelope of supported workflow commands. Their
		# properties and message bodies are sanitized by the same filter below.
		if (match(line, /^::(error|warning|notice|group|endgroup|add-mask|debug)( [^:]*)?::/)) {
			command_end = RLENGTH
			line = literal(substr(line, 1, command_end), "::", workflow_delimiter, 0) substr(line, command_end + 1)
		}
		# IMAP literal mailbox names may occupy several following lines.
		if (folder_bytes > 0) {
			folder_bytes -= length(line) + 1
			next
		}
		if (line ~ /-----BEGIN (.* )?(CERTIFICATE|PUBLIC KEY|PRIVATE KEY)-----/) {
			pem = 1; print "[" alias " certificate or key data redacted]"; fflush(); next
		}
		if (pem) {
			if (line ~ /-----END (.* )?(CERTIFICATE|PUBLIC KEY|PRIVATE KEY)-----/) pem = 0
			next
		}
		# TXT key fragments can be quoted across lines. A continuation consists
		# solely of an opaque key chunk; ordinary test output ends this state.
		key_chunk = line; gsub(/[[:space:]\"]/, "", key_chunk)
		if (dkim_continuation && length(key_chunk) >= 16 && line ~ /^[[:space:]\"]*[A-Za-z0-9+\/=]+[[:space:]\"]*$/) {
			print "[" alias " key continuation redacted]"; fflush(); next
		}
		dkim_continuation = (line ~ /v=DKIM1/ && line ~ /p[[:space:]]*=/)
		line = protect(line)
		# DNSBL 127/8 responses are status/error codes, not the target address.
		dnsbl_response = (line ~ /LISTED on (zen\.spamhaus\.org|bl\.spamcop\.net|b\.barracudacentral\.org|dnsbl\.sorbs\.net):/)
		# Certificate DNs can contain customer organizations and locations too.
		if (line ~ /^[[:space:]]*(subject|issuer)[[:space:]]*=/) sub(/=.*/, "=" token("certificate identity"), line)
		if (line ~ /^[[:space:]]*(Peer certificate|Server certificate)[[:space:]]*:/) sub(/:.*/, ": " token("certificate identity"), line)
		if (line ~ /^[[:space:]]*depth=[0-9]+ /) sub(/ .*/, " " token("certificate identity"), line)
		# Keep folder flags/hierarchy for all IMAP string encodings (quoted,
		# atom and literal), but never emit potentially identifying mailbox names.
		if (match(line, /^\* LIST \([^)]*\)[[:space:]]+(\"[^\"]*\"|NIL)[[:space:]]+/)) {
			folder_start = RLENGTH
			folder_name = substr(line, folder_start + 1)
			if (folder_name ~ /^\{[0-9]+\}[[:space:]]*$/) {
				gsub(/[^0-9]/, "", folder_name); folder_bytes = folder_name + 0
			}
			line = substr(line, 1, folder_start) token("folder")
		}
		# Protocol greetings are free text and often include short hostnames or
		# organization names which cannot be recognized as DNS names. Preserve
		# reply codes and the useful IMAP capabilities, not the identity prose.
		if (match(line, /^[[:space:]]*(<[-~][[:space:]]*)?220[- ]/)) line = substr(line, 1, RLENGTH) token("SMTP greeting")
		if (match(line, /^\* (OK|BYE)[[:space:]]+/)) {
			greeting_start = RLENGTH
			greeting_body = substr(line, greeting_start + 1)
			if (match(greeting_body, /^\[CAPABILITY[^]]*\]/)) line = substr(line, 1, greeting_start) substr(greeting_body, 1, RLENGTH) " " token("IMAP greeting")
			else line = substr(line, 1, greeting_start) token("IMAP greeting")
		}
		if (line ~ /^[[:space:]]*(\"[^\"]*\"|[^[:space:]]+)[[:space:]]+ACTIVE[[:space:]]*$/) line = token("Sieve script") " ACTIVE"
		line = keys(line)
		line = pattern(line, "[A-Za-z0-9.!#$%&\047*+/=?^_`{|}~-]+@[A-Za-z0-9][A-Za-z0-9._-]*", "email")
		line = ipv6(line)
		line = pattern(line, "[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+", "IP")
		line = pattern(line, "([A-Za-z0-9_][A-Za-z0-9_-]*\\.)+[A-Za-z][A-Za-z0-9-]+\\.?", "host")
		print restore(line)
		fflush()
	}'
}

# Sanitize JSON string values, preserving JSON types, keys and escaping.
# OctoMailTest uses fixed schema keys, never target-derived keys. Raw input is
# temporary, mode 0600, and removed on exit; no parse error echoes raw JSON.
omt_privacy_json() (
	local alias=${1:-OctoMailTest} domain=${2:-} host=${3:-} email=${4:-} password=${5:-}
	local scratch path value sanitized trailing
	if ! omt_privacy_validate_alias "$alias"; then
		printf '%s\n' 'Invalid private alias: use 1-64 letters, digits, underscores or hyphens.' >&2
		return 2
	fi
	umask 077
	scratch=$(mktemp -d "${TMPDIR:-/tmp}/octomailtest-json.XXXXXX") || return 1
	trap 'rm -rf -- "$scratch"' EXIT
	cat > "$scratch/input.json" || return 1
	if ! jq -se 'length == 1' "$scratch/input.json" >/dev/null 2>&1; then
		printf '%s\n' 'Invalid JSON report; private output withheld.' >&2
		return 1
	fi
	jq -c 'if type == "string" then [] else paths(strings) end' "$scratch/input.json" > "$scratch/paths" || return 1
	: > "$scratch/updates.jsonl"
	while IFS= read -r path; do
		value=$(jq -j --argjson path "$path" 'getpath($path)' "$scratch/input.json" || exit 1; printf '\034') || return 1
		value=${value%$'\034'}
		trailing=${value##*[!$'\n']}
		sanitized=$(printf '%s' "$value" | omt_privacy_filter "$alias" "$domain" "$host" "$email" "$password") || return 1
		sanitized+=$trailing
		jq -nc --argjson path "$path" --arg value "$sanitized" '{path: $path, value: $value}' >> "$scratch/updates.jsonl" || return 1
	done < "$scratch/paths"
	jq --slurpfile updates "$scratch/updates.jsonl" 'reduce $updates[] as $update (. ; setpath($update.path; $update.value))' "$scratch/input.json"
)
