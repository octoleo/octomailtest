#!/usr/bin/env bash
set -euo pipefail
# Offline command-contract fixtures, not live mail-server validation.
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TEMP="$(mktemp -d)"
trap 'rm -rf -- "$TEMP"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
contains() { grep -Fq -- "$2" "$1" || fail "expected: $2"; }
excludes() { if grep -Fq -- "$2" "$1"; then fail "unexpected: $2"; fi; }
count_lines() {
  local expected="$1" pattern="$2" file="${3:-$OMT_COMMANDS}" actual
  actual="$(grep -Ec -- "$pattern" "$file" || true)"
  [[ "$actual" == "$expected" ]] || fail "expected $expected lines matching $pattern, got $actual"
}
unset OCTOMAILTEST_SMTP_PORT OCTOMAILTEST_SMTPS_PORT OCTOMAILTEST_SMTP_RELAY_PORT OCTOMAILTEST_IMAP_PORT OCTOMAILTEST_IMAPS_PORT OCTOMAILTEST_SIEVE_PORT
unset OCTOMAILTEST_PRIVATE OCTOMAILTEST_ALIAS OCTOMAILTEST_HISTORY OCTOMAILTEST_HISTORY_KEEP OCTOMAILTEST_HISTORY_DIR
export OCTOMAILTEST_WRAPPED=1
export OCTOMAILTEST_DOMAIN=example.invalid OCTOMAILTEST_HOST=mx.example.invalid
export OCTOMAILTEST_EMAIL=fixture@example.invalid OCTOMAILTEST_PASS=fixture-password
export OMT_COMMANDS="$TEMP/commands.log" OMT_PAYLOADS="$TEMP/payloads.log" OMT_VIOLATIONS="$TEMP/violations.log"
OMT_REAL_TIMEOUT="$(command -v timeout)"
export OMT_REAL_TIMEOUT
export OMT_IMPLICIT_PORTS='465 993 2465 2993'
mkdir "$TEMP/bin"
cat > "$TEMP/bin/fixture" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
tool="${0##*/}"
printf '%s\n' "$tool $*" >> "$OMT_COMMANDS"
listed() { [[ " $1 " == *" $2 "* ]]; }
violation() { printf '%s\n' "$*" >> "$OMT_VIOLATIONS"; exit 90; }
case "$tool" in
  timeout) exec "$OMT_REAL_TIMEOUT" "$@" ;;
  sleep) exit 0 ;;
  dig)
    case "$*" in
      *zen.spamhaus.org*) [[ -z "${OMT_SPAMHAUS_REPLY:-}" ]] || printf '%s\n' "$OMT_SPAMHAUS_REPLY" ;;
      *bl.spamcop.net*) [[ -z "${OMT_SPAMCOP_REPLY:-}" ]] || printf '%s\n' "$OMT_SPAMCOP_REPLY" ;;
      *' -x '*) printf '%s\n' 'mx.example.invalid.' ;;
      *' A '*) printf '%s\n' '192.0.2.10' ;;
      *' TXT '*) printf '%s\n' '"v=spf1 -all"' ;;
    esac
    ;;
  nc)
    port="${!#}"
    if listed "${OMT_CLOSED_PORTS:-}" "$port"; then exit 1; fi
    if [[ " $* " == *' -zv '* ]]; then printf '%s\n' 'Connection succeeded: open'
    else printf '%s\n' '220 mx.example.invalid fixture'; fi
    ;;
  swaks)
    args=" $* "
    port=''
    while [[ $# -gt 0 ]]; do
      case "$1" in --port) port="$2"; shift ;; esac
      shift
    done
    [[ -n "$port" ]] || violation 'SMTP command omitted its port'
    [[ "$args" != *' --tls-optional '* && "$args" != *' --tls-on-connect-optional '* ]] || violation 'optional TLS allowed plaintext'
    if listed "$OMT_IMPLICIT_PORTS" "$port"; then
      [[ "$args" == *' --tls-on-connect '* && "$args" != *' --tls '* ]] || violation "wrong SMTP TLS mode on $port"
    else
      [[ "$args" == *' --tls '* && "$args" != *' --tls-on-connect '* ]] || violation "wrong SMTP TLS mode on $port"
    fi
    if listed "${OMT_CLOSED_PORTS:-} ${OMT_TLS_FAILED_PORTS:-}" "$port"; then violation "SMTP command reached unavailable TLS endpoint $port"; fi
    if listed "${OMT_AUTH_FAILED_PORTS:-}" "$port" && [[ "$args" == *' --auth '* ]]; then exit 1; fi
    printf '%s\n' '250-fixture' '250-AUTH LOGIN' '250-PIPELINING' '250-SIZE 10000000' '250-8BITMIME' '250 DSN'
    ;;
  openssl)
    args=" $* "
    payload="$(cat)"
    if [[ "$1" == x509 ]]; then
      [[ -n "$payload" ]] || exit 1
      case "$args" in
        *' -enddate '*) printf '%s\n' 'notAfter=Jan 1 00:00:00 2099 GMT' ;;
        *' -text '*) printf '%s\n' 'X509v3 Subject Alternative Name:' '    DNS:mx.example.invalid' 'X509v3 Key Usage:' ;;
        *) printf '%s\n' 'subject=CN=mx.example.invalid' 'issuer=fixture' 'notAfter=Jan 1 00:00:00 2099 GMT' ;;
      esac
    else
      port='' mode=implicit protocol=''
      while [[ $# -gt 0 ]]; do
        case "$1" in
          -connect) port="${2##*:}"; shift ;;
          -starttls) mode=starttls; protocol="$2"; shift ;;
        esac
        shift
      done
      printf '%s\n' "port=$port mode=$mode protocol=$protocol payload=${payload//$'\n'/\\n}" >> "$OMT_PAYLOADS"
      if [[ "$args" == *' -brief '* && "$payload" == *fixture-password* ]]; then violation 'TLS probe sent credentials'; fi
      if listed "${OMT_CLOSED_PORTS:-} ${OMT_TLS_FAILED_PORTS:-}" "$port"; then
        [[ "$payload" != *fixture-password* ]] || violation "credentials reached failed TLS endpoint $port"
        exit 1
      fi
      if listed "$OMT_IMPLICIT_PORTS" "$port"; then expected_mode=implicit; else expected_mode=starttls; fi
      if [[ "$mode" != "$expected_mode" ]]; then
        [[ "$payload" != *fixture-password* ]] || violation "credentials sent before TLS detection on $port"
        exit 1
      fi
      if listed "${OMT_FAIL_AFTER_CERT_PORTS:-}" "$port" && [[ "$args" != *' -brief '* ]]; then
        marker="$OMT_COMMANDS.$port.cert-first"
        if [[ -f "$marker" ]]; then exit 1; fi
        : > "$marker"
      fi
      if listed "${OMT_AUTH_FAILED_PORTS:-}" "$port" && [[ "$payload" == *LOGIN* ]]; then
        auth_reply=('a001 NO Authentication failed')
      else
        auth_reply=('a001 OK LOGIN completed' '* LIST () "/" "INBOX"' 'a002 OK SELECT completed' '+ idling' 'a003 OK IDLE completed')
      fi
      printf '%s\n' 'CONNECTION ESTABLISHED' 'Protocol version: TLSv1.3' 'Protocol  : TLSv1.3' 'Cipher    : FIXTURE' \
        '* OK fixture ready' '* CAPABILITY IMAP4rev1 IDLE COMPRESS=DEFLATE' "${auth_reply[@]}" '"SIEVE" "fileinto"' 'OK LISTSCRIPTS'
    fi
    ;;
esac
BASH
chmod +x "$TEMP/bin/fixture"
for tool in dig nc openssl swaks sleep timeout; do ln -s fixture "$TEMP/bin/$tool"; done
export PATH="$TEMP/bin:$PATH"
cd "$TEMP"

run_case() {
  local name="$1" expected_rc="$2" actual_rc provider client_calls swaks_calls
  shift 2
  : > "$OMT_COMMANDS"
  : > "$OMT_PAYLOADS"
  : > "$OMT_VIOLATIONS"
  rm -f "$OMT_COMMANDS".*.cert-first
  set +e
  bash "$ROOT/src/mail" "$@" > "$TEMP/$name.log" 2>&1
  actual_rc=$?
  set -e
  [[ "$actual_rc" == "$expected_rc" ]] || { cat "$TEMP/$name.log" >&2; fail "$name: expected exit $expected_rc, got $actual_rc"; }
  [[ ! -s "$OMT_VIOLATIONS" ]] || { cat "$OMT_VIOLATIONS" >&2; fail "$name: insecure transport command"; }
  for provider in zen.spamhaus.org bl.spamcop.net b.barracudacentral.org dnsbl.sorbs.net; do
    count_lines 1 "^dig .*10.2.0.192.$provider"
  done
  count_lines 0 '^swaks .* --tls(-on-connect)?-optional( |$)'
  client_calls="$(grep -c '^openssl s_client ' "$OMT_COMMANDS" || true)"
  swaks_calls="$(grep -c '^swaks ' "$OMT_COMMANDS" || true)"
  count_lines "$client_calls" '^timeout [0-9]+ openssl s_client '
  count_lines "$swaks_calls" '^timeout [0-9]+ swaks '
  if [[ "$expected_rc" == 0 ]]; then
    contains "$TEMP/$name.log" 'All critical checks passed'
    excludes "$TEMP/$name.log" '❌'
  fi
}
smtp_tested() {
  local port="$1" mode="$2"
  count_lines 3 "^swaks .* --port $port( |$)"
  if [[ "$mode" == implicit ]]; then
    count_lines 3 "^swaks .* --port $port .*--tls-on-connect( |$)"
  else
    count_lines 3 "^swaks .* --port $port .*--tls( |$)"
  fi
  count_lines 1 "^swaks .* --port $port .*--quit-after EHLO( |$)"
  count_lines 1 "^swaks .* --port $port .*--quit-after AUTH( |$)"
  count_lines 1 "^swaks .* --port $port .*--from fixture@example.invalid --to fixture@example.invalid( |$)"
  for version in tls1 tls1_1 tls1_2 tls1_3; do
    count_lines 1 "^openssl s_client .*mx.example.invalid:$port .*-$version( |$)"
  done
}
imap_tested() {
  local port="$1" mode="$2"
  contains "$OMT_PAYLOADS" "port=$port mode=$mode"
  count_lines 2 "^port=$port mode=$mode .*payload=.*LOGIN .*fixture-password" "$OMT_PAYLOADS"
}

# Defaults execute the existing diagnostics for both configured alternatives.
run_case defaults 0
smtp_tested 587 starttls
smtp_tested 465 implicit
imap_tested 143 starttls
imap_tested 993 implicit
count_lines 2 'SMTP AUTH LOGIN test' "$TEMP/defaults.log"
count_lines 2 'SMTP send test email' "$TEMP/defaults.log"
count_lines 2 'IMAP authentication successful' "$TEMP/defaults.log"
contains "$OMT_PAYLOADS" 'port=4190 mode=starttls protocol=sieve'
for provider in zen.spamhaus.org bl.spamcop.net b.barracudacentral.org dnsbl.sorbs.net; do contains "$TEMP/defaults.log" "NOT listed on $provider"; done
OCTOMAILTEST_DOMAIN='' run_case derived-domain 0
contains "$OMT_COMMANDS" 'dig +short MX example.invalid'
OCTOMAILTEST_SMTP_RELAY_PORT=0 OCTOMAILTEST_SMTP_PORT=0 OCTOMAILTEST_SMTPS_PORT=0 OCTOMAILTEST_IMAP_PORT=0 OCTOMAILTEST_IMAPS_PORT=0 OCTOMAILTEST_SIEVE_PORT=0 run_case zero-defaults 0
smtp_tested 587 starttls
smtp_tested 465 implicit
imap_tested 143 starttls
imap_tested 993 implicit
contains "$OMT_COMMANDS" 'nc -zv mx.example.invalid 25'
contains "$OMT_PAYLOADS" 'port=4190 mode=starttls protocol=sieve'
run_case empty-defaults 0 --smtp-relay-port '' --smtp-port '' --smtps-port '' --imap-port '' --imaps-port '' --sieve-port ''
smtp_tested 587 starttls
smtp_tested 465 implicit
imap_tested 143 starttls
imap_tested 993 implicit

# Normal endpoints warn when unavailable; designated secure endpoints must pass.
OMT_CLOSED_PORTS='587 143' run_case closed-normal-alternatives 0
smtp_tested 465 implicit
imap_tested 993 implicit
count_lines 0 '^swaks .* --port 587( |$)'
count_lines 0 '^port=143 .*fixture-password' "$OMT_PAYLOADS"
contains "$TEMP/closed-normal-alternatives.log" 'SMTP port 587'
contains "$TEMP/closed-normal-alternatives.log" 'IMAP port 143'
contains "$TEMP/closed-normal-alternatives.log" '⚠️'
OMT_CLOSED_PORTS=465 run_case secure-smtp-closed 1
smtp_tested 587 starttls
contains "$TEMP/secure-smtp-closed.log" 'SMTP: secure endpoint failed critical checks'
OMT_CLOSED_PORTS=993 run_case secure-imap-closed 1
imap_tested 143 starttls
contains "$TEMP/secure-imap-closed.log" 'IMAP: secure endpoint failed critical checks'
OMT_CLOSED_PORTS='587 465' run_case both-smtp-closed 1
contains "$TEMP/both-smtp-closed.log" 'SMTP: secure endpoint failed critical checks'
count_lines 0 '^swaks '
OMT_CLOSED_PORTS='143 993' run_case both-imap-closed 1
contains "$TEMP/both-imap-closed.log" 'IMAP: secure endpoint failed critical checks'
count_lines 0 '^port=(143|993) .*fixture-password' "$OMT_PAYLOADS"
OMT_TLS_FAILED_PORTS=587 run_case normal-tls-failed 0
count_lines 0 '^swaks .* --port 587( |$)'
smtp_tested 465 implicit
OMT_TLS_FAILED_PORTS=465 run_case secure-tls-failed 1
count_lines 0 '^swaks .* --port 465( |$)'
smtp_tested 587 starttls

# Authentication failures remain visible, and never skip the second endpoint.
OMT_FAIL_AFTER_CERT_PORTS=587 run_case certificate-display-failed 0
smtp_tested 587 starttls
smtp_tested 465 implicit
contains "$TEMP/certificate-display-failed.log" 'Could not retrieve SMTP certificate details'
contains "$TEMP/certificate-display-failed.log" 'SMTP: secure endpoint passed all critical checks'
OMT_AUTH_FAILED_PORTS=587 run_case normal-smtp-auth-failed 0
smtp_tested 587 starttls
smtp_tested 465 implicit
contains "$TEMP/normal-smtp-auth-failed.log" 'SMTP AUTH failed'
OMT_AUTH_FAILED_PORTS=465 run_case secure-smtp-auth-failed 1
smtp_tested 587 starttls
smtp_tested 465 implicit
contains "$TEMP/secure-smtp-auth-failed.log" 'SMTP: secure endpoint failed critical checks'
OMT_AUTH_FAILED_PORTS='587 465' run_case both-smtp-auth-failed 1
smtp_tested 587 starttls
smtp_tested 465 implicit
OMT_AUTH_FAILED_PORTS=143 run_case normal-imap-auth-failed 0
imap_tested 143 starttls
imap_tested 993 implicit
contains "$TEMP/normal-imap-auth-failed.log" 'IMAP authentication failed or incomplete'
OMT_AUTH_FAILED_PORTS=993 run_case secure-imap-auth-failed 1
imap_tested 143 starttls
imap_tested 993 implicit
contains "$TEMP/secure-imap-auth-failed.log" 'IMAP: secure endpoint failed critical checks'
OMT_AUTH_FAILED_PORTS='143 993' run_case both-imap-auth-failed 1
imap_tested 143 starttls
imap_tested 993 implicit

# Secure-port overrides infer TLS-on-connect and deduplicate equal alternatives.
run_case secure-overrides 0 --smtp-port 465 --imap-port 993
smtp_tested 465 implicit
imap_tested 993 implicit
count_lines 3 '^swaks '
count_lines 0 '^swaks .* --port 587( |$)'
count_lines 0 '^port=143 ' "$OMT_PAYLOADS"
contains "$TEMP/secure-overrides.log" 'SMTPS required'
contains "$TEMP/secure-overrides.log" 'IMAPS required'
excludes "$TEMP/secure-overrides.log" 'SMTP submission alternative'
excludes "$TEMP/secure-overrides.log" 'IMAP alternative'
OMT_AUTH_FAILED_PORTS='465 993' run_case equal-secure-failure 1 --smtp-port 465 --imap-port 993
contains "$TEMP/equal-secure-failure.log" 'SMTP: secure endpoint failed critical checks'
contains "$TEMP/equal-secure-failure.log" 'IMAP: secure endpoint failed critical checks'

# Custom ports discover their TLS handshake without extra mode configuration.
run_case custom 0 --smtp-port 2465 --smtps-port 2587 --imap-port 2993 --imaps-port 2143
smtp_tested 2465 implicit
smtp_tested 2587 starttls
imap_tested 2993 implicit
imap_tested 2143 starttls
contains "$OMT_PAYLOADS" 'port=2465 mode=starttls protocol=smtp payload='
contains "$OMT_PAYLOADS" 'port=2993 mode=starttls protocol=imap payload='
OMT_AUTH_FAILED_PORTS=2587 run_case custom-secure-auth-failed 1 --smtp-port 2465 --smtps-port 2587
smtp_tested 2465 implicit
smtp_tested 2587 starttls
contains "$TEMP/custom-secure-auth-failed.log" 'SMTP: secure endpoint failed critical checks'
OMT_IMPLICIT_PORTS='465 993 2465 2993 4190' run_case implicit-sieve 0
contains "$OMT_PAYLOADS" 'port=4190 mode=implicit'
OMT_CLOSED_PORTS='25 4190' run_case optional-services 0
contains "$TEMP/optional-services.log" 'Sieve'
contains "$TEMP/optional-services.log" '⚠️'
run_case relay-override 0 --smtp-relay-port 2525
contains "$OMT_COMMANDS" 'mx.example.invalid 2525'

# Environment, config and private mode use the same transport decisions.
OCTOMAILTEST_SMTP_PORT=2465 OCTOMAILTEST_SMTPS_PORT=2587 OCTOMAILTEST_IMAP_PORT=2993 OCTOMAILTEST_IMAPS_PORT=2143 run_case environment 0
smtp_tested 2465 implicit
imap_tested 2993 implicit
cat > fixture.config <<'BASH'
SMTP_PORT=2465
SMTPS_PORT=2587
IMAP_PORT=2993
IMAPS_PORT=2143
BASH
run_case config 0 --config fixture.config
smtp_tested 2465 implicit
imap_tested 2143 starttls
OCTOMAILTEST_WRAPPED='' run_case private 0 --private --alias Bingo --smtp-port 2465 --smtps-port 2587 --imap-port 2993 --imaps-port 2143 --smtp-relay-port 2525 --sieve-port 14190
smtp_tested 2465 implicit
imap_tested 2993 implicit
for private in example.invalid fixture@example.invalid fixture-password 2465 2587 2993 2143 2525 14190; do excludes "$TEMP/private.log" "$private"; done
contains "$TEMP/private.log" 'Bingo'
contains "$TEMP/private.log" 'SMTP AUTH LOGIN test'
contains "$TEMP/private.log" 'IMAP authentication successful'
for role in 'SMTP submission alternative' 'SMTPS required' 'IMAP alternative' 'IMAPS required'; do contains "$TEMP/private.log" "$role"; done

# Spamhaus lookup errors are neither listings nor verified negative results.
# Genuine listings, and other providers' responses, retain critical failures.
for code in 127.255.255.254 127.255.255.255; do
  OMT_SPAMHAUS_REPLY="$code" run_case spamhaus-unavailable 0
  contains "$TEMP/spamhaus-unavailable.log" 'lookup unavailable; listing status unknown'
  excludes "$TEMP/spamhaus-unavailable.log" 'LISTED on zen.spamhaus.org'
  excludes "$TEMP/spamhaus-unavailable.log" 'NOT listed on zen.spamhaus.org'
done
OMT_SPAMHAUS_REPLY=127.0.0.2 run_case spamhaus-listed 1
contains "$TEMP/spamhaus-listed.log" 'LISTED on zen.spamhaus.org: 127.0.0.2'
OMT_SPAMCOP_REPLY=127.255.255.254 run_case other-provider-positive 1
contains "$TEMP/other-provider-positive.log" 'LISTED on bl.spamcop.net: 127.255.255.254'

# Removed mode options and incomplete port overrides reject before diagnostics.
for option in '--smtp-tls-mode implicit' '--smtp-starttls-port 587' '--smtps-port' '--imaps-port'; do
  : > "$OMT_COMMANDS"
  # Intentional splitting: each fixture is one or two fixed arguments.
  # shellcheck disable=SC2086
  if bash "$ROOT/src/mail" $option > "$TEMP/rejected.log" 2>&1; then fail "accepted invalid option: $option"; fi
  [[ ! -s "$OMT_COMMANDS" ]] || fail 'invalid options reached diagnostics'
done
printf '%s\n' 'Offline mail transport and DNSBL configuration tests passed (no live server validation).'
