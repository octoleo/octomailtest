#!/usr/bin/env bash
set -euo pipefail

# Offline command-contract fixtures: these exercise the real diagnostic script,
# but do not connect to or certify a mail server.
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TEMP="$(mktemp -d)"
trap 'rm -rf -- "$TEMP"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
contains() { grep -Fq -- "$2" "$1" || fail "expected: $2"; }
count_lines() {
	local expected="$1" pattern="$2" actual
	actual="$(grep -Ec -- "$pattern" "$OMT_COMMANDS" || true)"
	[[ "$actual" == "$expected" ]] || fail "expected $expected calls matching $pattern, got $actual"
}

unset OCTOMAILTEST_SMTP_PORT OCTOMAILTEST_SMTP_TLS_MODE OCTOMAILTEST_SMTP_STARTTLS_PORT OCTOMAILTEST_SMTPS_PORT
unset OCTOMAILTEST_IMAP_PORT OCTOMAILTEST_SIEVE_PORT
unset OCTOMAILTEST_PRIVATE OCTOMAILTEST_ALIAS OCTOMAILTEST_HISTORY OCTOMAILTEST_HISTORY_KEEP OCTOMAILTEST_HISTORY_DIR
export OCTOMAILTEST_WRAPPED=1
export OCTOMAILTEST_DOMAIN=example.invalid OCTOMAILTEST_HOST=mx.example.invalid
export OCTOMAILTEST_EMAIL=fixture@example.invalid OCTOMAILTEST_PASS=fixture-password
export OMT_COMMANDS="$TEMP/commands.log"
mkdir "$TEMP/bin"
cat > "$TEMP/bin/fixture" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
tool="${0##*/}"
printf '%s\n' "$tool $*" >> "$OMT_COMMANDS"
case "$tool" in
	sleep) exit 0 ;;
	dig)
		case "$*" in
			*' -x '*) printf '%s\n' 'mx.example.invalid.' ;;
			*' A '*) printf '%s\n' '192.0.2.10' ;;
			*' TXT '*) printf '%s\n' '"v=spf1 -all"' ;;
		esac
		;;
	nc)
		if [[ " $* " == *' -zv '* ]]; then printf '%s\n' 'Connection succeeded: open'
		else printf '%s\n' '220 mx.example.invalid fixture'; fi
		;;
	swaks)
		[[ " ${*} " == *" --port ${OMT_EXPECT_PORT} "* ]] || exit 90
		[[ " ${*} " == *" ${OMT_EXPECT_SWAKS_TLS} "* ]] || exit 91
		[[ " ${*} " != *' --tls-optional '* && " ${*} " != *' --tls-on-connect-optional '* ]] || exit 92
		[[ "${OMT_FAIL_SMTP:-0}" == 0 ]] || exit 93
		printf '%s\n' '250-fixture' '250-AUTH LOGIN' '250-PIPELINING' '250-SIZE 10000000' '250-8BITMIME' '250 DSN'
		;;
	openssl)
		# Consume pipe input so fixture success does not introduce SIGPIPE failures.
		cat >/dev/null
		if [[ "$1" == x509 ]]; then
			case " $* " in
				*' -enddate '*) printf '%s\n' 'notAfter=Jan 1 00:00:00 2099 GMT' ;;
				*' -text '*) printf '%s\n' 'X509v3 Subject Alternative Name:' '    DNS:mx.example.invalid' 'X509v3 Key Usage:' ;;
				*) printf '%s\n' 'subject=CN=mx.example.invalid' 'issuer=fixture' 'notAfter=Jan 1 00:00:00 2099 GMT' ;;
			esac
		else
			if [[ "${OMT_FAIL_STARTTLS:-0}" == 1 && " $* " == *' -starttls smtp '* ]]; then exit 94; fi
			printf '%s\n' 'Protocol  : TLSv1.2' 'Cipher    : FIXTURE' '* OK fixture ready' \
				'* CAPABILITY IMAP4rev1 IDLE COMPRESS=DEFLATE' 'a001 OK LOGIN completed' \
				'* LIST () "/" "INBOX"' 'a002 OK SELECT completed' '+ idling' \
				'a003 OK IDLE completed' '"SIEVE" "fileinto"' 'OK LISTSCRIPTS'
		fi
		;;
esac
BASH
chmod +x "$TEMP/bin/fixture"
for tool in dig nc openssl swaks sleep; do ln -s fixture "$TEMP/bin/$tool"; done
export PATH="$TEMP/bin:$PATH"
cd "$TEMP"

run_case() {
	local name="$1" port="$2" mode="$3" starttls_port="$4" smtps_port="$5" expected_rc="$6" actual_rc starttls_calls smtps_calls
	shift 6
	export OMT_EXPECT_PORT="$port"
	if [[ "$mode" == implicit ]]; then OMT_EXPECT_SWAKS_TLS=--tls-on-connect; else OMT_EXPECT_SWAKS_TLS=--tls; fi
	export OMT_EXPECT_SWAKS_TLS
	: > "$OMT_COMMANDS"
	set +e
	bash "$ROOT/src/mail" "$@" > "$TEMP/$name.log" 2>&1
	actual_rc=$?
	set -e
	[[ "$actual_rc" == "$expected_rc" ]] || { cat "$TEMP/$name.log" >&2; fail "$name: expected exit $expected_rc, got $actual_rc"; }

	# EHLO, authenticated login and sending all keep the selected mandatory TLS mode.
	count_lines 3 "^swaks .* --port $port( |$)"
	count_lines 3 "^swaks .* $OMT_EXPECT_SWAKS_TLS( |$)"
	count_lines 1 '^swaks .* --quit-after EHLO( |$)'
	count_lines 1 '^swaks .* --quit-after AUTH( |$)'
	count_lines 1 '^swaks .* --from fixture@example.invalid --to fixture@example.invalid( |$)'
	count_lines 3 '^swaks '
	count_lines 0 '^swaks .* --tls(-on-connect)?-optional( |$)'

	# Both separate certificate diagnostics remain present, even with implicit submission.
	starttls_calls=2
	[[ "${OMT_FAIL_STARTTLS:-0}" == 0 ]] || starttls_calls=1
	count_lines "$starttls_calls" "^openssl s_client -starttls smtp -connect mx.example.invalid:$starttls_port "
	smtps_calls=2
	if [[ "$mode" == implicit && "$port" == "$smtps_port" ]]; then smtps_calls=4; fi
	count_lines "$smtps_calls" "^openssl s_client -connect mx.example.invalid:$smtps_port -servername mx.example.invalid$"
	# Selected-submission expiration/SAN checks use the same TLS mode as submission.
	if [[ "$mode" == implicit ]]; then
		count_lines 0 '^swaks .* --tls( |$)'
		if [[ "$port" != "$smtps_port" ]]; then
			count_lines 2 "^openssl s_client -connect mx.example.invalid:$port -servername mx.example.invalid$"
		fi
		count_lines 0 "^openssl s_client .* -connect mx.example.invalid:$port .* -starttls smtp"
		count_lines 0 "^openssl s_client -starttls smtp -connect mx.example.invalid:$port "
	else
		count_lines 0 '^swaks .* --tls-on-connect( |$)'
		count_lines 2 "^openssl s_client -connect mx.example.invalid:$port -servername mx.example.invalid -starttls smtp$"
	fi
	for version in tls1 tls1_1 tls1_2 tls1_3; do
		if [[ "$mode" == implicit ]]; then
			count_lines 1 "^openssl s_client -connect mx.example.invalid:$port -servername mx.example.invalid -$version$"
		else
			count_lines 1 "^openssl s_client -connect mx.example.invalid:$port -servername mx.example.invalid -starttls smtp -$version$"
		fi
	done
	for endpoint in 25 "$smtps_port" "$starttls_port" 993 4190 "$port"; do
		contains "$TEMP/$name.log" "Port $endpoint:"
	done
	# Existing IMAPS remains TLS-on-connect without SMTP's STARTTLS option.
	count_lines 0 '^openssl s_client .*mx.example.invalid:993 .* -starttls '
	contains "$TEMP/$name.log" 'IMAP authentication successful'
	contains "$TEMP/$name.log" 'SMTP AUTH LOGIN test'
	contains "$TEMP/$name.log" 'SMTP send test email'
	if [[ "$expected_rc" == 0 ]]; then contains "$TEMP/$name.log" 'All critical checks passed'; fi
}

run_case defaults 587 starttls 587 465 0
run_case auto-smtps 465 implicit 587 465 0 --smtp-port 465
run_case custom-implicit-derived 2465 implicit 587 2465 0 --smtp-port 2465 --smtp-tls-mode implicit
run_case custom-auto-starttls 2587 starttls 2587 465 0 --smtp-port 2587
run_case explicit-starttls 465 starttls 465 2465 0 --smtp-port 465 --smtp-tls-mode starttls --smtps-port 2465
run_case custom-implicit 2465 implicit 1587 3465 0 --smtp-port 2465 --smtp-tls-mode implicit --smtp-starttls-port 1587 --smtps-port 3465
run_case custom-starttls 2587 starttls 1587 3465 0 --smtp-port 2587 --smtp-tls-mode starttls --smtp-starttls-port 1587 --smtps-port 3465
OCTOMAILTEST_WRAPPED='' run_case private-custom-implicit 2465 implicit 1587 3465 0 --private --alias Bingo --smtp-port 2465 --smtp-tls-mode implicit --smtp-starttls-port 1587 --smtps-port 3465
for private in mx.example.invalid fixture@example.invalid fixture-password; do
	if grep -Fq -- "$private" "$TEMP/private-custom-implicit.log"; then fail 'private transport run exposed an identifier'; fi
done
contains "$TEMP/private-custom-implicit.log" 'Bingo'

# Environment and sourced config reach the same transport decisions.
OCTOMAILTEST_SMTP_PORT=2465 OCTOMAILTEST_SMTP_TLS_MODE=IMPLICIT OCTOMAILTEST_SMTP_STARTTLS_PORT=1587 OCTOMAILTEST_SMTPS_PORT=3465 \
	run_case environment 2465 implicit 1587 3465 0
OCTOMAILTEST_SMTP_PORT=2465 OCTOMAILTEST_SMTP_TLS_MODE=implicit OCTOMAILTEST_SMTP_STARTTLS_PORT=0 OCTOMAILTEST_SMTPS_PORT=0 \
	run_case environment-derived-ports 2465 implicit 587 2465 0
cat > fixture.config <<'BASH'
SMTP_PORT=2465
SMTP_TLS_MODE=implicit
SMTP_STARTTLS_PORT=1587
SMTPS_PORT=3465
BASH
run_case config 2465 implicit 1587 3465 0 --config fixture.config
cat > derived.config <<'BASH'
SMTP_PORT=2587
SMTP_TLS_MODE=starttls
SMTP_STARTTLS_PORT=0
SMTPS_PORT=0
BASH
run_case config-derived-ports 2587 starttls 2587 465 0 --config derived.config
run_case cli-derived-ports 465 implicit 587 465 0 --smtp-port 465 --smtp-starttls-port 0 --smtps-port 0
OCTOMAILTEST_SMTP_PORT=2465 OCTOMAILTEST_SMTP_TLS_MODE=implicit OCTOMAILTEST_SMTP_STARTTLS_PORT=1587 OCTOMAILTEST_SMTPS_PORT=3465 \
	run_case cli-over-environment 587 starttls 2587 4465 0 --smtp-port 587 --smtp-tls-mode starttls --smtp-starttls-port 2587 --smtps-port 4465

# TLS or SMTP failure must remain a failed run, with no plaintext retry.
OMT_FAIL_SMTP=1 run_case failed-submission 465 implicit 587 465 1 --smtp-port 465
contains "$TEMP/failed-submission.log" 'SMTP EHLO over implicit TLS failed'
contains "$TEMP/failed-submission.log" 'SMTP AUTH failed'
contains "$TEMP/failed-submission.log" 'Failed to send test email via SMTP'
OMT_FAIL_STARTTLS=1 run_case failed-separate-starttls 465 implicit 587 465 1 --smtp-port 465
contains "$TEMP/failed-separate-starttls.log" 'Unable to fetch certificate via SMTP STARTTLS on 587'

# Invalid or missing transport options stop before any server commands run.
for option in '--smtp-tls-mode plaintext' '--smtp-tls-mode' '--smtp-starttls-port' '--smtps-port'; do
	: > "$OMT_COMMANDS"
	# Intentional splitting: every fixture above is one or two fixed arguments.
	# shellcheck disable=SC2086
	if bash "$ROOT/src/mail" $option > "$TEMP/rejected.log" 2>&1; then fail "accepted invalid option: $option"; fi
	[[ ! -s "$OMT_COMMANDS" ]] || fail 'invalid transport reached external commands'
done
printf '%s\n' 'Offline SMTP transport argument/configuration tests passed (no live server validation).'
