#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck disable=SC1091
source "$ROOT/lib/privacy.sh"
TEMP=$(mktemp -d)
trap 'rm -rf -- "$TEMP"' EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
contains() { grep -Fq -- "$2" "$1" || fail "expected $2 in $(basename "$1")"; }
excludes() { if grep -Fiq -- "$2" "$1"; then fail "private data retained in $(basename "$1")"; fi; }

DOMAIN=customer.example
HOST=mx.customer.example
EMAIL='test+monitor@customer.example'
# Literal metacharacters deliberately test that values are never evaluated.
# shellcheck disable=SC2016
PASS='pA$s[.*]"\\&word'
PASS64=$(printf '%s' "$PASS" | base64 | tr -d '\n')
EMAIL64=$(printf '%s' "$EMAIL" | base64 | tr -d '\n')
AUTH64=$(printf '\0%s\0%s' "$EMAIL" "$PASS" | base64 | tr -d '\n')
export OMT_PRIVACY_CONFIG_DOMAIN=other.example OMT_PRIVACY_CONFIG_HOST=mx.other.example
# shellcheck disable=SC2016
export OMT_PRIVACY_CONFIG_EMAIL=admin@other.example OMT_PRIVACY_CONFIG_PASS='config$ecret'

# Require useful sanitized output while stdin is still open. A completed-output
# assertion cannot detect a filter that buffers every short line until EOF.
(
	mkfifo "$TEMP/live-input" "$TEMP/live-output"
	exec 8<> "$TEMP/live-input"
	(
		exec 8>&-
		# shellcheck disable=SC2016 # Positional arguments expand in the child shell.
		exec timeout 15 bash -c 'source "$1"; omt_privacy_filter Bingo "$2" "$3" "$4" "$5"' \
			_ "$ROOT/lib/privacy.sh" "$DOMAIN" "$HOST" "$EMAIL" "$PASS"
	) < "$TEMP/live-input" > "$TEMP/live-output" &
	filter_pid=$!
	trap 'exec 8>&- 9>&-; kill "$filter_pid" 2>/dev/null || true; wait "$filter_pid" 2>/dev/null || true' EXIT
	exec 9< "$TEMP/live-output"
	printf 'SMTP connectivity on %s:587\n' "$HOST" >&8
	IFS= read -r -t 5 first <&9 || fail 'private output did not arrive while diagnostic input remained open'
	[[ "$first" == 'SMTP connectivity on [Bingo host]:[Bingo port]' ]] || fail 'first live result was not anonymized'
	printf 'SMTP authentication for %s: PASS; password %s\n' "$EMAIL" "$PASS" >&8
	IFS= read -r -t 5 second <&9 || fail 'subsequent private output was buffered'
	[[ "$second" == 'SMTP authentication for [Bingo email]: PASS; password [Bingo redacted]' ]] || fail 'second live result lost privacy or detail'
	exec 8>&-
	wait "$filter_pid" || fail 'live privacy filter failed'
	exec 9>&-
	trap - EXIT
)

{
	printf 'Mail Diagnostics for %s\nHost: %s\nUser: %s\n' "$DOMAIN" "$HOST" "$EMAIL"
	printf 'Case variants: MX.CUSTOMER.EXAMPLE TEST+MONITOR@CUSTOMER.EXAMPLE\n'
	printf 'Password: %s\nLOGIN: %s %s\nPLAIN: %s\n' "$PASS" "$EMAIL64" "$PASS64" "$AUTH64"
	printf 'Config: %s %s %s %s\n' "$OMT_PRIVACY_CONFIG_DOMAIN" "$OMT_PRIVACY_CONFIG_HOST" "$OMT_PRIVACY_CONFIG_EMAIL" "$OMT_PRIVACY_CONFIG_PASS"
	printf 'MX 10 mx.other-company.example. PTR: reverse.provider.example.\n'
	printf 'rua=mailto:reports@third-party.example\n'
	printf 'IPv4: 198.51.100.42; IPv6: 2001:db8::42 [fe80::1%%eth0] ::ffff:192.0.2.4\n'
	printf 'subject=C = NA, O = Private Company, CN = mx.customer.example\n'
	printf 'issuer=C = US, O = Certificate Organization, CN = Test Issuer\n'
	printf 'Peer certificate: CN = mx.customer.example, O = Private Company\n'
	printf 'depth=0 C = NA, O = Private Company, CN = mx.customer.example\n'
	printf 'v=DKIM1; k=rsa; p=MIIBVeryLongPublicKey0123456789abc+/=; t=s\n'
	printf '%s\n' '-----BEGIN CERTIFICATE-----' 'UniqueCertificateBody0123' '-----END CERTIFICATE-----'
	printf '* LIST (\\HasNoChildren) "/" "Customer Contract Inbox"\n'
	printf 'Port 587: ✅ open\nProtocol: TLSv1.3\nCipher: TLS_AES_256_GCM_SHA384\n'
	printf 'notAfter=Oct 24 10:20:30 2027 GMT\nDays until expiration: 365\n'
	printf '⚠️ PTR differs from hostname\n❌ IMAP authentication failed\n'
	printf 'Reports: report.txt report.json summary.md\n'
} | omt_privacy_filter Bingo "$DOMAIN" "$HOST" "$EMAIL" "$PASS" > "$TEMP/output"
for private in "$DOMAIN" "$HOST" "$EMAIL" "$PASS" "$PASS64" "$EMAIL64" "$AUTH64" "$OMT_PRIVACY_CONFIG_PASS" \
	other.example other-company.example third-party.example provider.example 198.51.100.42 2001:db8 fe80::1 \
	192.0.2.4 'Private Company' 'Certificate Organization' MIIBVeryLongPublicKey UniqueCertificateBody 'Customer Contract Inbox'; do
	excludes "$TEMP/output" "$private"
done
for retained in '[Bingo domain]' '[Bingo host]' '[Bingo email]' 'Port [Bingo port]: ✅ open' 'Protocol: TLSv1.3' \
	TLS_AES_256_GCM_SHA384 'Days until expiration: 365' 'notAfter=Oct 24 10:20:30 2027 GMT' \
	'⚠️ PTR differs from hostname' '❌ IMAP authentication failed' 'report.txt report.json summary.md' 'k=rsa' 't=s'; do
	contains "$TEMP/output" "$retained"
done

# Both standard and custom ports stay private without changing unrelated numbers.
cat <<'EOF' | omt_privacy_filter Bingo "$DOMAIN" "$HOST" "$EMAIL" "$PASS" > "$TEMP/ports"
SMTP relay port 25: open
SMTP port: 587: authenticated
SMTPS on 465: TLS ready
IMAP 143: STARTTLS ready
IMAPS on 993: authenticated
Sieve port 4190: capabilities returned
STARTTLS on 25870
SMTP implicit TLS on 24650
IMAP port: from config file (default: 21143)
| IMAPS port | 21993 |
OCTOMAILTEST_SIEVE_PORT=24190
Ports: 25250, 25870 / 24650
=== Trying mx.customer.example:25870...
Connection to mx.customer.example (198.51.100.42) 24650 port [tcp/submissions] succeeded!
Connected to [2001:db8::42]:21993
connect:errno=111
Started: 2026-10-25T14:25:00Z
Completed: 2026-10-25T14:25:25Z
notAfter=Oct 25 14:25:00 2027 GMT
Protocol: TLSv1.3
Total runs: 25; passed: 143; failed: 587
Messages: 993; folders: 465
EOF
for port in 25250 25870 24650 21143 21993 24190; do excludes "$TEMP/ports" "$port"; done
for value in 'SMTP relay port [Bingo port]: open' 'SMTP port: [Bingo port]: authenticated' \
	'SMTPS on [Bingo port]: TLS ready' 'IMAP [Bingo port]: STARTTLS ready' \
	'IMAPS on [Bingo port]: authenticated' 'Sieve port [Bingo port]: capabilities returned' \
	'STARTTLS on [Bingo port]' 'SMTP implicit TLS on [Bingo port]' \
	'IMAP port: from config file (default: [Bingo port])' '| IMAPS port | [Bingo port] |' \
	'OCTOMAILTEST_SIEVE_PORT=[Bingo port]' 'Ports: [Bingo port], [Bingo port] / [Bingo port]' \
	'[Bingo host]:[Bingo port]' '[Bingo IP]]:[Bingo port]' 'connect:errno=111' \
	'Started: 2026-10-25T14:25:00Z' 'Completed: 2026-10-25T14:25:25Z' \
	'notAfter=Oct 25 14:25:00 2027 GMT' 'Protocol: TLSv1.3' \
	'Total runs: 25; passed: 143; failed: 587' 'Messages: 993; folders: 465'; do
	contains "$TEMP/ports" "$value"
done

# Identical discovered identifiers keep the same labels, even across lines.
printf 'alt.example.net\nalt.example.net\n' | omt_privacy_filter Bingo '' '' '' '' > "$TEMP/repeat"
[[ $(sort -u "$TEMP/repeat" | wc -l) == 1 ]] || fail 'unstable discovered hostname labels'

# A regex-looking password is a literal, not a pattern that eats other output.
printf 'secret .* still useful\n' | omt_privacy_filter Bingo '' '' '' '.*' > "$TEMP/literal"
contains "$TEMP/literal" 'secret [Bingo redacted] still useful'

# Overlapping literals must be hidden completely, not partly transformed.
printf 'Host: mx.customer.example\nPassword: .\n' | omt_privacy_filter Bingo "$DOMAIN" "$HOST" "$EMAIL" '.' > "$TEMP/overlap"
contains "$TEMP/overlap" 'Host: [Bingo host]'
excludes "$TEMP/overlap" customer

# Workflow command envelopes remain functional while their bodies are private.
printf '::group::Diagnostics for mx.customer.example\n::error title=OctoMailTest::Unable to reach 2001:db8::42\n::endgroup::\n' |
	omt_privacy_filter Bingo "$DOMAIN" "$HOST" "$EMAIL" "$PASS" > "$TEMP/commands"
contains "$TEMP/commands" '::group::Diagnostics for [Bingo host]'
contains "$TEMP/commands" '::error title=OctoMailTest::Unable to reach [Bingo IP]'
contains "$TEMP/commands" '::endgroup::'
printf '::warning title=mx.customer.example::2001:db8::42\n::add-mask::%s\n' "$PASS" |
	omt_privacy_filter Bingo "$DOMAIN" "$HOST" "$EMAIL" "$PASS" > "$TEMP/immediate-command"
contains "$TEMP/immediate-command" '::warning title=[Bingo host]::[Bingo IP]'
contains "$TEMP/immediate-command" '::add-mask::[Bingo redacted]'

# Preserve DMARC policies; redact complete DKIM keys including DNS TXT chunks.
printf '"v=DMARC1; p=reject; rua=mailto:postmaster@customer.example"\n"v=DKIM1; k=rsa; p=MIIBChunkOne" "ChunkTwoSecret+/="; t=s\n' |
	omt_privacy_filter Bingo "$DOMAIN" "$HOST" "$EMAIL" "$PASS" > "$TEMP/dns-keys"
contains "$TEMP/dns-keys" 'p=reject'
contains "$TEMP/dns-keys" 'k=rsa'
contains "$TEMP/dns-keys" 't=s'
excludes "$TEMP/dns-keys" MIIBChunkOne
excludes "$TEMP/dns-keys" ChunkTwoSecret

# Server greetings and mailbox labels are free text, not necessarily DNS names.
printf '220 short-mailhost ESMTP SecretCompany\n<- 220 other-server SecretCompany\n* OK [CAPABILITY IMAP4rev1 IDLE] SecretCompany ready\n* LIST (\\HasNoChildren) "/" ClientFolder\n* LIST (\\HasNoChildren) "/" {16}\nClientLiteralBox\n* LIST (\\HasNoChildren) "/" "Private Folder"\nscript-name ACTIVE\n' |
	omt_privacy_filter Bingo "$DOMAIN" "$HOST" "$EMAIL" "$PASS" > "$TEMP/protocol"
for private in short-mailhost other-server SecretCompany ClientFolder ClientLiteralBox 'Private Folder' script-name; do excludes "$TEMP/protocol" "$private"; done
contains "$TEMP/protocol" '220 [Bingo SMTP greeting]'
contains "$TEMP/protocol" '* OK [CAPABILITY IMAP4rev1 IDLE] [Bingo IMAP greeting]'
contains "$TEMP/protocol" '[Bingo Sieve script] ACTIVE'

printf 'v=DKIM1; p = FirstKeyChunkAAAA\n"SecondKeyChunk0123456789"\nSMTP tests completed\n' |
	omt_privacy_filter Bingo "$DOMAIN" "$HOST" "$EMAIL" "$PASS" > "$TEMP/key-continuation"
excludes "$TEMP/key-continuation" FirstKeyChunk
excludes "$TEMP/key-continuation" SecondKeyChunk
contains "$TEMP/key-continuation" 'SMTP tests completed'

# The fixed DNSBL names describe the check, not the tested system.
printf 'LISTED on zen.spamhaus.org: 127.0.0.2\nNOT listed on bl.spamcop.net\n' |
	omt_privacy_filter Bingo "$DOMAIN" "$HOST" "$EMAIL" "$PASS" > "$TEMP/providers"
contains "$TEMP/providers" 'LISTED on zen.spamhaus.org: 127.0.0.2'
contains "$TEMP/providers" 'NOT listed on bl.spamcop.net'
printf 'Lookup unavailable on zen.spamhaus.org: 127.255.255.254; listing status unknown\nAddress: 127.255.255.254\n' |
	omt_privacy_filter Bingo "$DOMAIN" "$HOST" "$EMAIL" "$PASS" > "$TEMP/provider-errors"
contains "$TEMP/provider-errors" 'Lookup unavailable on zen.spamhaus.org: 127.255.255.254; listing status unknown'
contains "$TEMP/provider-errors" 'Address: [Bingo IP]'
printf 'zen.spamhaus.org\n' | omt_privacy_filter Bingo zen.spamhaus.org '' '' '' > "$TEMP/provider-target"
contains "$TEMP/provider-target" '[Bingo domain]'

# Multiline passwords and terminal colouring must not bypass redaction.
printf 'first-secret\nsecond-secret\n\033[31mcustomer.example\033[0m\n' |
	omt_privacy_filter Bingo "$DOMAIN" '' '' $'first-secret\nsecond-secret' > "$TEMP/multiline"
excludes "$TEMP/multiline" first-secret
excludes "$TEMP/multiline" second-secret
excludes "$TEMP/multiline" "$DOMAIN"

# Private JSON preserves structure, booleans, number types, escaping and newlines.
jq -n --arg domain "$DOMAIN" --arg email "$EMAIL" --arg password "$PASS" \
	--arg output "$(cat "$TEMP/output")" \
	'{target:{domain:$domain,email:$email},password:$password,output:$output,status:"passed",failures:0,ok:true,nothing:null}' |
	omt_privacy_json Bingo "$DOMAIN" "$HOST" "$EMAIL" "$PASS" > "$TEMP/result.json"
jq -e '.target.domain == "[Bingo domain]" and .target.email == "[Bingo email]" and .password == "[Bingo redacted]" and .status == "passed" and .failures == 0 and .ok == true and .nothing == null' "$TEMP/result.json" >/dev/null || fail 'JSON data changed'
excludes "$TEMP/result.json" "$DOMAIN"
excludes "$TEMP/result.json" "$PASS"
printf '{"value":"hello\\n\\n"}' | omt_privacy_json Bingo '' '' '' '' > "$TEMP/newlines.json"
jq -e '.value == "hello\n\n"' "$TEMP/newlines.json" >/dev/null || fail 'JSON trailing newlines lost'

# Port fields become labeled redactions; unrelated numeric metadata keeps its type.
printf '%s\n' '{"target":{"smtp_relay_port":25250,"smtp_port":25870,"smtps_port":24650,"imap_port":21143,"imaps_port":21993,"sieve_port":24190},"runs":25,"failures":0,"when":"2026-10-25T14:25:00Z","endpoint":{"port":25870},"unknown":{"smtp_port":null}}' |
	omt_privacy_json Bingo "$DOMAIN" "$HOST" "$EMAIL" "$PASS" > "$TEMP/ports.json"
jq -e '.target.smtp_relay_port == "[Bingo SMTP relay port]"
	and .target.smtp_port == "[Bingo SMTP port]" and .target.smtps_port == "[Bingo SMTPS port]"
	and .target.imap_port == "[Bingo IMAP port]" and .target.imaps_port == "[Bingo IMAPS port]"
	and .target.sieve_port == "[Bingo Sieve port]" and .endpoint.port == "[Bingo port]"
	and .unknown.smtp_port == null and .runs == 25 and .failures == 0
	and .when == "2026-10-25T14:25:00Z"' "$TEMP/ports.json" >/dev/null || fail 'private port metadata changed unrelated values'
for port in 25250 25870 24650 21143 21993 24190; do excludes "$TEMP/ports.json" "$port"; done

# Invalid aliases and invalid JSON fail closed without echoing the input.
if printf 'private-domain.example\n' | omt_privacy_filter 'unsafe.example' '' '' '' '' > "$TEMP/rejected" 2>&1; then fail 'invalid alias accepted'; fi
excludes "$TEMP/rejected" unsafe.example
excludes "$TEMP/rejected" private-domain.example
if printf '{"private":"customer.example"' | omt_privacy_json Bingo '' '' '' '' > "$TEMP/invalid-json" 2>&1; then fail 'invalid JSON accepted'; fi
excludes "$TEMP/invalid-json" customer.example
printf 'PASS: private stream and JSON tests\n'
