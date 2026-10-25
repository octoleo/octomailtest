#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TEMP="$(mktemp -d)"
trap 'rm -rf -- "$TEMP"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
contains() { grep -Fq -- "$2" "$1" || fail "expected diagnostic text: $2"; }
excludes() { if grep -Fq -- "$2" "$1"; then fail 'private value escaped'; fi; }
expect_exit() {
	local expected="$1" actual
	shift
	set +e
	"$@"
	actual=$?
	set -e
	[[ "$actual" == "$expected" ]] || fail "expected exit $expected, got $actual"
}
export OMT_TEST_LIBRARY="$ROOT/lib"
export OCTOMAILTEST_DOMAIN='customer.example' OCTOMAILTEST_HOST='mx.customer.example'
# shellcheck disable=SC2016
export OCTOMAILTEST_EMAIL='test@customer.example' OCTOMAILTEST_PASS='literal$secret.*'
cat > "$TEMP/diagnostic" <<'BASH'
#!/usr/bin/env bash
set -euo pipefail
source "$OMT_TEST_LIBRARY/cli.sh"
omt_cli_dispatch diagnostic "$0" "$@"
if [[ -f ./.octomailtest ]]; then source ./.octomailtest; fi
printf 'DNS: %s\nHost: %s\nMailbox: %s\n' "$OCTOMAILTEST_DOMAIN" "$OCTOMAILTEST_HOST" "$OCTOMAILTEST_EMAIL"
printf 'Secret: %s\n' "$OCTOMAILTEST_PASS" >&2
printf 'Port 587: open\nProtocol: TLSv1.3\n'
if [[ "${MOCK_RC:-0}" != 0 ]]; then
  printf '❌ Authentication failed for %s\n' "$OCTOMAILTEST_EMAIL" >&2
  printf '❌ Critical failures: 1\n' >&2
fi
exit "${MOCK_RC:-0}"
BASH
cd "$TEMP"
bash "$TEMP/diagnostic" > plain.log 2>&1
contains plain.log customer.example
bash "$TEMP/diagnostic" --private --alias Bingo > private.log 2>&1
for private in "$OCTOMAILTEST_DOMAIN" "$OCTOMAILTEST_EMAIL" "$OCTOMAILTEST_PASS"; do excludes private.log "$private"; done
contains private.log '[Bingo host]'
contains private.log 'Port [Bingo port]: open'
excludes private.log '587'
contains private.log 'Protocol: TLSv1.3'
MOCK_RC=7 expect_exit 7 bash "$TEMP/diagnostic" --private --alias Bingo > failure.log 2>&1
contains failure.log '❌ Authentication failed'
excludes failure.log customer.example

# A config password differing from the environment is still protected.
# shellcheck disable=SC2016
printf 'PASS=%q\nprintf "Config password: %%s\\n" "$PASS"\n' 'config-secret-value' > .octomailtest
bash "$TEMP/diagnostic" --private --alias Bingo > config.log 2>&1
excludes config.log config-secret-value
rm .octomailtest

# Missing and invalid feature arguments fail without echoing their values.
expect_exit 1 bash "$TEMP/diagnostic" --private --alias > rejected.log 2>&1
expect_exit 1 bash "$TEMP/diagnostic" --private --alias 'sensitive.example' >> rejected.log 2>&1
expect_exit 1 bash "$TEMP/diagnostic" --private --history-keep 0 >> rejected.log 2>&1
excludes rejected.log sensitive.example

# Both success and diagnostic failure enter history and retain only N reports.
bash "$TEMP/diagnostic" --private --alias Bingo --history --history-keep 2 > /dev/null
MOCK_RC=7 expect_exit 7 bash "$TEMP/diagnostic" --private --alias Bingo --history --history-keep 2 > /dev/null
bash "$TEMP/diagnostic" --private --alias Bingo --history --history-keep 2 > /dev/null
jq -e '.total_runs == 3 and .passed_runs == 2 and .failed_runs == 1 and (.runs | length) == 2' octomailtest-history/Bingo/history.json >/dev/null
jq -e '.failures == 1' octomailtest-history/Bingo/runs/2/report.json >/dev/null
if grep -RFq customer.example octomailtest-history; then fail 'history contains private identifier'; fi

# Exercise the real Docker entrypoint with mock diagnostics, without Docker or network.
mkdir -p app/lib
cp "$ROOT/docker/entrypoint.sh" app/entrypoint.sh
cp "$ROOT/lib/"*.sh app/lib/
cat > app/mail <<'BASH'
#!/usr/bin/env bash
printf 'SMTP test for %s\nPort 587: open\n' "$OCTOMAILTEST_HOST"
printf 'Private stderr for %s\n' "$OCTOMAILTEST_EMAIL" >&2
exit "${MOCK_RC:-0}"
BASH
cat > app/imap <<'BASH'
#!/usr/bin/env bash
printf 'IMAP test for %s\n' "$OCTOMAILTEST_HOST"
touch imap-executed
BASH
chmod +x app/mail app/imap
cd app
bash entrypoint.sh both --private --alias Bingo --json --log results.log > result.json
jq -e '.status == "passed" and .private == true and (.output | contains("SMTP test")) and (.output | contains("IMAP test"))' result.json >/dev/null
contains results.log 'Port [Bingo port]: open'
excludes results.log '587'
excludes results.log customer.example
excludes result.json customer.example
rm imap-executed
MOCK_RC=7 expect_exit 7 bash entrypoint.sh both --private --alias Bingo --history --history-keep 2 > failure.log 2>&1
[[ ! -e imap-executed ]] || fail 'changed existing both-mode fail-fast order'
jq -e '.total_runs == 1 and .failed_runs == 1' octomailtest-history/Bingo/history.json >/dev/null
contains failure.log 'SMTP test'
excludes failure.log customer.example

# Preserve the original JSON command-substitution behavior, including its
# legacy status: both diagnostics execute and jq returns success after mail fails.
MOCK_RC=7 expect_exit 0 bash entrypoint.sh both --json > original.json 2> original.stderr
[[ -e imap-executed ]] || fail 'original JSON fixture did not run IMAP'
rm imap-executed
MOCK_RC=7 expect_exit 0 bash entrypoint.sh both --private --alias Bingo --json > private-failed.json 2> private-failed.stderr
[[ -e imap-executed ]] || fail 'private JSON changed existing diagnostic ordering'
jq -e '.exit_code == 0 and .status == "passed" and (.output | contains("SMTP test")) and (.output | contains("IMAP test"))' private-failed.json >/dev/null
excludes private-failed.json customer.example
excludes private-failed.stderr customer.example
contains private-failed.stderr '[Bingo email]'

# Legacy copied standalone scripts still reach their original help without lib/.
mkdir "$TEMP/standalone"
cp "$ROOT/src/mail" "$TEMP/standalone/mail"
bash "$TEMP/standalone/mail" --help > "$TEMP/help.log"
contains "$TEMP/help.log" 'Domain name'
expect_exit 1 bash "$TEMP/standalone/mail" --private > "$TEMP/no-library.log" 2>&1
contains "$TEMP/no-library.log" 'accompanying lib directory'
printf '%s\n' 'CLI privacy/history tests passed.'
