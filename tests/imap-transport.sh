#!/usr/bin/env bash
set -euo pipefail

# Offline fixtures exercise the real script, not live server availability.
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TEMP="$(mktemp -d)"
trap 'rm -rf -- "$TEMP"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
contains() { grep -Fq -- "$2" "$1" || fail "expected diagnostic: $2"; }
excludes() { if grep -Fq -- "$2" "$1"; then fail "unexpected diagnostic: $2"; fi; }
count() {
	local expected="$1" pattern="$2" actual
	actual="$(grep -Ec -- "$pattern" "$OMT_IMAP_CALLS" || true)"
	[[ "$actual" == "$expected" ]] || fail "expected $expected calls matching $pattern; got $actual"
}
unset OCTOMAILTEST_IMAP_PORT OCTOMAILTEST_IMAPS_PORT
unset OCTOMAILTEST_PRIVATE OCTOMAILTEST_ALIAS OCTOMAILTEST_HISTORY OCTOMAILTEST_HISTORY_DIR OCTOMAILTEST_HISTORY_KEEP
export OCTOMAILTEST_WRAPPED=1 OCTOMAILTEST_CI=1
export OCTOMAILTEST_HOST=mx.fixture.invalid OCTOMAILTEST_EMAIL=mailbox@fixture.invalid OCTOMAILTEST_PASS=fixture-password
export OMT_IMAP_CALLS="$TEMP/calls.log"
export OMT_IMAP_ENDPOINTS='143=starttls 993=implicit'
mkdir "$TEMP/bin"
cat > "$TEMP/bin/sleep" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
cat > "$TEMP/bin/openssl" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
mode=implicit
phase=conversation
port=''
while (( $# )); do
	case "$1" in
		-connect) port="${2##*:}"; shift 2 ;;
		-starttls) [[ "$2" == imap ]] || exit 90; mode=starttls; shift 2 ;;
		-brief) phase=probe; shift ;;
		*) shift ;;
	esac
done
payload="$(cat)"
auth=no
[[ "$payload" != *' LOGIN '* ]] || auth=yes
printf 'port=%s mode=%s phase=%s auth=%s\n' "$port" "$mode" "$phase" "$auth" >> "$OMT_IMAP_CALLS"
if [[ "$phase" == probe && -n "$payload" ]]; then
	echo 'Probe unexpectedly received a protocol command' >&2
	exit 91
fi
expected=closed
for endpoint in $OMT_IMAP_ENDPOINTS; do
	[[ "${endpoint%%=*}" != "$port" ]] || expected="${endpoint#*=}"
done
if [[ "$mode" != "$expected" ]]; then
	[[ "$auth" != yes ]] || printf 'Credentials sent without detected TLS\n' >> "$OMT_IMAP_CALLS"
	exit 92
fi
if [[ "$phase" == probe ]]; then
	printf 'Protocol version: TLSv1.3\nCiphersuite: FIXTURE\n' >&2
	exit 0
fi
printf '* OK fixture ready\r\n'
if [[ "$payload" == *CAPABILITY* ]]; then
	if [[ "${OMT_IMAP_FAIL_CAPABILITY:-}" == "$port" ]]; then
		printf 'a001 BAD CAPABILITY rejected\r\n'
	else
		printf '* CAPABILITY IMAP4rev1 IDLE\r\na001 OK CAPABILITY completed\r\n'
	fi
elif [[ "$auth" == yes ]]; then
	if [[ "${OMT_IMAP_FAIL_AUTH:-}" == "$port" ]]; then
		printf 'a001 NO Authentication failed\r\na002 NO Not authenticated\r\na003 NO Not authenticated\r\n'
	else
		printf 'a001 OK LOGIN completed\r\n'
		if [[ "$payload" == *' LIST '* ]]; then
			printf '* LIST () "/" "INBOX"\r\na002 OK LIST completed\r\n'
		elif [[ "$payload" == *' SELECT '* ]]; then
			printf '* 0 EXISTS\r\na002 OK SELECT completed\r\n'
			if [[ "${OMT_IMAP_NO_IDLE:-}" == "$port" ]]; then
				printf 'a003 BAD IDLE unavailable\r\n'
			else
				printf '+ idling\r\na003 OK IDLE completed\r\n'
			fi
		fi
	fi
fi
printf '* BYE fixture closed\r\n'
MOCK
chmod +x "$TEMP/bin/sleep" "$TEMP/bin/openssl"
export PATH="$TEMP/bin:$PATH"
run_case() {
	local name="$1" expected_rc="$2" actual_rc
	shift 2
	mkdir "$TEMP/$name"
	: > "$OMT_IMAP_CALLS"
	set +e
	(cd "$TEMP/$name" && bash "$ROOT/src/imap" "$@") > "$TEMP/$name.log" 2>&1
	actual_rc=$?
	set -e
	[[ "$actual_rc" == "$expected_rc" ]] || { cat "$TEMP/$name.log" >&2; fail "$name: expected exit $expected_rc, got $actual_rc"; }
	excludes "$OMT_IMAP_CALLS" 'phase=probe auth=yes'
	excludes "$OMT_IMAP_CALLS" 'Credentials sent without detected TLS'
	if [[ "$expected_rc" == 0 ]]; then
		excludes "$TEMP/$name.log" '❌'
		contains "$TEMP/$name.log" 'IMAP test completed successfully'
	else
		contains "$TEMP/$name.log" 'Required secure IMAP endpoint failed'
	fi
}
run_case defaults 0
count 1 '^port=143 mode=starttls phase=probe auth=no$'
count 1 '^port=993 mode=implicit phase=probe auth=no$'
count 4 '^port=143 mode=starttls phase=conversation '
count 4 '^port=993 mode=implicit phase=conversation '
for test_name in 'Test 1: IMAP Greeting and CAPABILITY' 'Test 2: IMAP Authentication' 'Test 3: IMAP List Folders' 'Test 4: IMAP SELECT and IDLE'; do
	[[ "$(grep -Fc "$test_name" "$TEMP/defaults.log")" == 2 ]] || fail 'did not run all four conversations on both ports'
done

# Closed alternatives remain visible; required secure failures stay fatal.
OMT_IMAP_ENDPOINTS='993=implicit' run_case closed-alternative 0
contains "$TEMP/closed-alternative.log" 'IMAP alternative port 143: unavailable'
contains "$TEMP/closed-alternative.log" 'The IMAP alternative failed; the required secure endpoint passed'
count 0 '^port=143 .* phase=conversation '
count 4 '^port=993 mode=implicit phase=conversation '
OMT_IMAP_ENDPOINTS='143=starttls' run_case closed-secure 1
count 4 '^port=143 mode=starttls phase=conversation '
count 0 '^port=993 .* phase=conversation '
OMT_IMAP_ENDPOINTS='' run_case both-closed 1
count 0 ' phase=conversation '

# Authentication outcomes must be honored, and the second endpoint still runs.
OMT_IMAP_FAIL_AUTH=143 run_case alternative-auth-failure 0
contains "$TEMP/alternative-auth-failure.log" 'IMAP authentication failed or did not complete'
count 4 '^port=993 mode=implicit phase=conversation '
OMT_IMAP_FAIL_AUTH=993 run_case secure-auth-failure 1
contains "$TEMP/secure-auth-failure.log" 'IMAP authentication failed or did not complete'
OMT_IMAP_FAIL_CAPABILITY=993 run_case secure-capability-failure 1
OMT_IMAP_NO_IDLE=993 run_case optional-idle 0
contains "$TEMP/optional-idle.log" 'optional IDLE extension unavailable'

# Custom ports detect their handshake, independent of the endpoint role.
OMT_IMAP_ENDPOINTS='1143=implicit 1993=starttls' run_case custom-cli 0 --imap-port 1143 --imaps-port 1993
count 1 '^port=1143 mode=starttls phase=probe auth=no$'
count 1 '^port=1143 mode=implicit phase=probe auth=no$'
count 4 '^port=1143 mode=implicit phase=conversation '
count 4 '^port=1993 mode=starttls phase=conversation '
OMT_IMAP_ENDPOINTS='1143=implicit 1993=starttls' OCTOMAILTEST_IMAP_PORT=1143 OCTOMAILTEST_IMAPS_PORT=1993 run_case custom-environment 0
count 4 '^port=1143 mode=implicit phase=conversation '
count 4 '^port=1993 mode=starttls phase=conversation '
printf 'IMAP_PORT=1143\nIMAPS_PORT=1993\n' > "$TEMP/imap.config"
OMT_IMAP_ENDPOINTS='1143=implicit 1993=starttls' run_case custom-config 0 --config "$TEMP/imap.config"
OCTOMAILTEST_IMAP_PORT=1143 OCTOMAILTEST_IMAPS_PORT=1993 run_case cli-over-environment 0 --imap-port 143 --imaps-port 993
count 4 '^port=143 mode=starttls phase=conversation '
count 4 '^port=993 mode=implicit phase=conversation '

# Legacy --imap-port 993 remains valid and duplicate endpoints run only once.
run_case duplicate-secure 0 --imap-port 993
count 1 '^port=993 mode=implicit phase=probe auth=no$'
count 4 '^port=993 mode=implicit phase=conversation '
run_case zero-defaults 0 --imap-port 0 --imaps-port 0
count 4 '^port=143 mode=starttls phase=conversation '
count 4 '^port=993 mode=implicit phase=conversation '

# Private findings preserve protocol/role labels while hiding target and ports.
OCTOMAILTEST_WRAPPED='' run_case private-defaults 0 --private --alias Bingo
for value in mx.fixture.invalid mailbox@fixture.invalid fixture-password 'port 143' 'port 993'; do
	excludes "$TEMP/private-defaults.log" "$value"
done
contains "$TEMP/private-defaults.log" 'IMAP alternative port [Bingo port]'
contains "$TEMP/private-defaults.log" 'IMAPS required port [Bingo port]'
contains "$TEMP/private-defaults.log" 'IMAP authentication'

# Standalone help and early validation remain available without the library.
mkdir "$TEMP/standalone"
cp "$ROOT/src/imap" "$TEMP/standalone/imap"
bash "$TEMP/standalone/imap" --help > "$TEMP/help.log"
contains "$TEMP/help.log" '--imaps-port'
for value in bad -1 65536; do
	: > "$OMT_IMAP_CALLS"
	if bash "$ROOT/src/imap" --imaps-port "$value" > "$TEMP/invalid.log" 2>&1; then fail 'accepted invalid port'; fi
	[[ ! -s "$OMT_IMAP_CALLS" ]] || fail 'invalid port reached server commands'
done
printf '%s\n' 'Offline IMAP paired-port transport and outcome tests passed (no live server validation).'
