<h2><img align="middle" src="https://raw.githubusercontent.com/odb/official-bash-logo/master/assets/Logos/Icons/PNG/64x64.png" >
OctoMailTest - Automated Email testing suite
</h2>

Written by Llewellyn van der Merwe (@llewellynvdm)

**OctoMailTest** is a deep diagnostic tool for validating mail infrastructure:
SMTP, IMAP, TLS, DNS, Sieve, authentication, and deliverability.

It can be run:
- as a **stand-alone Bash tool**
- as a **minimal Docker container**
- or as a **GitHub Action** that publishes the report as a workflow artifact

---

## What it does

OctoMailTest performs:

### DNS diagnostics
- MX
- SPF
- DKIM
- DMARC
- BIMI
- MTA-STS
- TLS-RPT

### Connectivity
- SMTP relay (25), SMTP submission (587), and SMTPS (465)
- IMAP (143) and IMAPS (993)
- ManageSieve (4190)

### TLS & security
- Certificate validation
- Expiry checks
- TLS downgrade protection
- Cipher & protocol tests

### Authentication
- SMTP AUTH (LOGIN)
- IMAP LOGIN
- Sieve AUTH

### Deliverability
- RBL blacklist checks
- PTR validation
- SMTP feature discovery

All configured SMTP and IMAP ports are tested, including their available
features. SMTPS and IMAPS must pass for the run to succeed. A closed or
failed normal SMTP or IMAP alternative produces a warning. Failure of a
required secure endpoint remains critical even if the other alternative works.
DNS, relay, RBL, and Sieve checks remain part of the diagnostic suite.
DNSBL provider errors, including Spamhaus lookup restrictions, are reported
as lookup unavailable/status unknown warnings. A confirmed listing remains
a failure.

The mail diagnostic sends a test email to the configured mailbox itself
through each working SMTP alternative when `swaks` is installed. Equal
configured ports are tested once. It does not delete mail.

---

## Environment variables

Only the host, mailbox address, and password are required:

```bash
OCTOMAILTEST_HOST=mx1.email.host
OCTOMAILTEST_EMAIL=your@email.com
OCTOMAILTEST_PASS=secret
```

The DNS domain is derived from the mailbox address. Set
`OCTOMAILTEST_DOMAIN` only when the DNS checks should use another domain.
All standard ports are tested by default; override only custom ports:

```bash
OCTOMAILTEST_SMTP_RELAY_PORT=25
OCTOMAILTEST_SMTP_PORT=587
OCTOMAILTEST_SMTPS_PORT=465
OCTOMAILTEST_IMAP_PORT=143
OCTOMAILTEST_IMAPS_PORT=993
OCTOMAILTEST_SIEVE_PORT=4190
```

You may also use `.octomailtest`; its keys omit the `OCTOMAILTEST_` prefix
(see [`.octomailtest.example`](.octomailtest.example)).

SMTP and IMAP transport detection is automatic: standard ports provide
the initial TLS hint, and bounded probes identify custom ports. STARTTLS
upgrades the connection before authentication; implicit TLS encrypts it
from the start. Credentials are never sent over a plaintext fallback.

---

## Docker usage

### Run everything (default)

```bash
docker run --rm \
  -e OCTOMAILTEST_HOST=mx1.email.host \
  -e OCTOMAILTEST_EMAIL=you@email.com \
  -e OCTOMAILTEST_PASS=secret \
  octoleo/octomailtest
```

### Mail only

```bash
docker run octoleo/octomailtest mail
```

### IMAP only

```bash
docker run octoleo/octomailtest imap
```

---

## CI / Quiet mode

Suppress banners and separators:

```bash
docker run octoleo/octomailtest --ci
```

Useful for pipelines and logs.

## Private diagnostics and run history

### Keep the findings, anonymize the target

Use `--private --alias Bingo` to retain the diagnostic messages while
anonymizing the target. The action equivalents are `private: true` and
`alias: Bingo`. Private mode is independent of `--quiet`: test names,
outcomes, warnings, and failure explanations remain visible.

Private text output streams each sanitized line as the diagnostic scripts
emit it, including in the running action's log. Saved reports and the job
summary are generated after the diagnostics finish.

Configured domains, hosts, and mailbox addresses receive consistent alias
labels. Discovered domains, addresses, IPs, port numbers, and identifying
certificate or authentication data are redacted as well. Protocol names,
test outcomes, TLS versions, ciphers, and certificate expiry remain visible.
Anonymization happens before output is published to the console, report
files, GitHub annotations, or the job summary. Both stdout and stderr are
covered. JSON and file logging receive the anonymized findings too.
Existing content in an append-only `--log` file is not rewritten; use a new
file when switching from ordinary output to private output. In the action,
identifying artifact names and report locations are replaced with alias-based
names, and runner machine names are anonymized. Only the three generated
report files are uploaded, so unrelated files in a report directory are excluded.

Private mode changes presentation, not which diagnostics run or how their
results are evaluated.

With the usual `OCTOMAILTEST_*` credentials already exported, run from the
repository root:

```bash
./src/mail --private --alias Bingo
./src/imap --private --alias Bingo
```

Keep the repository's `lib` directory with the scripts when using these
options. Private text output uses the existing shell tools; `jq` is needed
for history and Docker JSON output. The new privacy and history settings
are supplied through CLI options or the environment, not `.octomailtest`.

Or use Docker:

```bash
docker run --rm \
  -e OCTOMAILTEST_DOMAIN \
  -e OCTOMAILTEST_HOST \
  -e OCTOMAILTEST_EMAIL \
  -e OCTOMAILTEST_PASS \
  octoleo/octomailtest both --private --alias Bingo
```

The alias is intentionally public. Use an unrelated label rather than a
real domain, mailbox, or server name. Aliases start with a letter or digit
and contain letters, digits, underscores, or hyphens, up to 64 characters.
The default alias is `OctoMailTest`. Supply credentials through environment variables or
GitHub secrets; private mode cannot redact commands your shell prints
before starting the program.

### Retain a bounded run history

Enable history with `--history`. `--history-keep` sets how many recent runs
to retain (a positive integer, default `10`), and `--history-dir` sets the
repository-relative directory (default `octomailtest-history`). For example:

```bash
./src/mail --private --alias Bingo \
  --history --history-keep 20 --history-dir octomailtest-history
```

Each alias has its own directory:

| Path | Contents |
|---|---|
| `octomailtest-history/Bingo/README.md` | Run counter, cumulative outcomes, and links to the retained findings |
| `octomailtest-history/Bingo/history.json` | Machine-readable cumulative counters and recent run entries |
| `octomailtest-history/Bingo/runs/<sequence>/` | The run's text report, JSON report, and Markdown summary |

Entries include UTC timestamps, the result, and the recorded findings.
Failed diagnostic runs are retained too. Pruning old reports does not reset
the cumulative run counter. Different aliases have independent counters
and retention limits. A history write failure is reported as an error; it
does not silently replace an existing history or reset its counter.

Retention applies to the current history directory and index. If history
is committed to Git, older reports remain accessible in earlier commits;
pruning the current files does not rewrite Git history.

History follows the current privacy mode. To prevent a private history
from retaining previously unredacted reports, an alias directory cannot
mix private and non-private runs. Start a new directory when changing the
privacy mode of an existing history.

The generated history README provides links to the reports. Link it from
your repository README with:

```markdown
[Bingo test history](octomailtest-history/Bingo/README.md)
```

OctoMailTest does not rewrite the caller's root README. Stand-alone history
writes local files; committing them is a separate operation. Container
history needs a writable bind mount or volume to survive `docker run --rm`.

### Commit daily history from GitHub Actions

The `history-commit` action option checks out the calling repository into
`.octomailtest-history-repository` and commits the alias's history there after
recording the result. This separate checkout preserves the caller's existing
working files and staged changes. It requires
`history: true`, a branch-based run (`schedule`, `workflow_dispatch`, or
`push`), and `contents: write` permission. Pull request runs cannot push
history. Only the selected alias's history directory is staged; unrelated
files are not included, and pushes never use force.

This complete example keeps the last ten detailed private reports. All
target values come from secrets; the public name is Bingo:

```yaml
name: Bingo

on:
  workflow_dispatch:
  schedule:
    - cron: '17 2 * * *' # Daily at 02:17 UTC / 04:17 Namibia time

permissions:
  contents: write

# Use the same group in every workflow that commits history to this repo.
concurrency:
  group: octomailtest-history
  cancel-in-progress: false

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - name: Test Bingo
        uses: octoleo/octomailtest@master
        with:
          host: ${{ secrets.BINGO_HOST }}
          email: ${{ secrets.BINGO_EMAIL }}
          pass: ${{ secrets.BINGO_PASS }}
          domain: ${{ secrets.BINGO_DOMAIN }}
          smtp-relay-port: ${{ secrets.BINGO_SMTP_RELAY_PORT }}
          smtp-port: ${{ secrets.BINGO_SMTP_PORT }}
          smtps-port: ${{ secrets.BINGO_SMTPS_PORT }}
          imap-port: ${{ secrets.BINGO_IMAP_PORT }}
          imaps-port: ${{ secrets.BINGO_IMAPS_PORT }}
          sieve-port: ${{ secrets.BINGO_SIEVE_PORT }}
          private: true
          alias: Bingo
          quiet: false
          history: true
          history-keep: 10
          history-dir: octomailtest-history
          history-commit: true
```

Pin the action to the reviewed commit or release when deploying it. No
separate checkout or commit step is needed for `history-commit`. Failed
diagnostic results are recorded before the action applies `fail-on-error`,
so a history update does not turn a failed check into a successful one.
Branch protection rules must permit the workflow's history commits.

Only `BINGO_HOST`, `BINGO_EMAIL`, and `BINGO_PASS` are required. Leave
`BINGO_DOMAIN` unset to derive the DNS domain from the email address.
All six port secrets are optional; leave them unset to test the standard
ports. Add a port secret only when that service uses a custom port.

The CLI environment equivalents are:

| Environment variable | Default |
|---|---|
| `OCTOMAILTEST_PRIVATE` | `false` |
| `OCTOMAILTEST_ALIAS` | `OctoMailTest` |
| `OCTOMAILTEST_HISTORY` | `false` |
| `OCTOMAILTEST_HISTORY_KEEP` | `10` |
| `OCTOMAILTEST_HISTORY_DIR` | `octomailtest-history` |

---

## JSON output

```bash
docker run octoleo/octomailtest --json
```

Output:

```json
{
  "action": "both",
  "output": "..."
}
```

Perfect for GitHub Actions, monitoring, or ingestion.

---

## Logging to file

```bash
docker run \
  -e OCTOMAILTEST_LOG=/logs/out.log \
  -v $(pwd)/logs:/logs \
  octoleo/octomailtest
```

Logs always go to stdout; file logging is additive.

---

## GitHub Action

OctoMailTest ships as a GitHub Action (`action.yml`), so any repository can
run the full diagnostic suite from a workflow and keep the report as a
workflow artifact. The action installs the tools it needs on the runner when
they are missing (`bash`, `openssl`, `dig`, `nc`, GNU `coreutils`, `jq` and
`swaks`), so it runs on the GitHub-hosted Ubuntu and macOS runners and on
self-hosted runners or job containers without any preparation.

### Quick start

```yaml
name: Mail health

on:
  workflow_dispatch:
  schedule:
    - cron: '0 6 * * 1'   # every Monday at 06:00 UTC

jobs:
  octomailtest:
    runs-on: ubuntu-latest
    steps:
      - name: Test the mail service
        uses: octoleo/octomailtest@master
        with:
          host: ${{ secrets.OCTOMAILTEST_HOST }}
          email: ${{ secrets.OCTOMAILTEST_EMAIL }}
          pass: ${{ secrets.OCTOMAILTEST_PASS }}
          private: true
```

No checkout step is needed. When the run finishes:

- the **job summary** shows the result table, the failures, the warnings and
  the full report
- the **artifact** `octomailtest-report` holds `report.txt` (full text
  report), `report.json` (machine-readable) and `summary.md`
- the job **fails** when critical failures were found (set
  `fail-on-error: false` to only record the result in the outputs)
- every critical failure is shown as an **annotation** on the run

Pin the action to a tag or commit (`octoleo/octomailtest@v1.0.1`) for
reproducible runs.

### As a reusable workflow

The same diagnostics are available as a reusable workflow, which is handy
when the caller only wants to pass values and secrets:

```yaml
jobs:
  octomailtest:
    uses: octoleo/octomailtest/.github/workflows/octomailtest.yml@master
    with:
      host: mx1.example.com
      email: postmaster@example.com
    secrets:
      OCTOMAILTEST_PASS: ${{ secrets.OCTOMAILTEST_PASS }}
```

`host` and `email` may also be provided as the secrets `OCTOMAILTEST_HOST`
and `OCTOMAILTEST_EMAIL` instead of inputs, so a caller whose repository
already defines the `OCTOMAILTEST_*` secrets can simply use
`secrets: inherit`. The workflow accepts the same options as the action
(`mode`, ports, `quiet`, `timeout`, `fail-on-error`, `artifact-name`,
`retention-days`, `private`, `alias`, `runs-on`) and exposes `status`, `exit-code`, `failures`,
`warnings`, `artifact-name` and `artifact-url` as outputs.

The reusable workflow keeps read-only repository permissions and checks
out OctoMailTest itself. For run history and automatic history commits,
use the composite action directly, as shown in
[Commit daily history from GitHub Actions](#commit-daily-history-from-github-actions).

In this repository the workflow also runs on every pull request and push to
`master` (using the repository's `OCTOMAILTEST_*` secrets) and can be
started manually from the **Actions** tab. Push and pull-request runs always
enable private output, including port redaction.

### Inputs

| Input | Default | Description |
|---|---|---|
| `domain` | from email | Optional domain for DNS checks (`OCTOMAILTEST_DOMAIN`). Defaults to the part after `@` in the mailbox address. |
| `host` | | Mail server host (`OCTOMAILTEST_HOST`). Required unless `config-file` provides it. |
| `email` | | Mailbox address (`OCTOMAILTEST_EMAIL`). Required unless `config-file` provides it. |
| `pass` | | Mailbox password (`OCTOMAILTEST_PASS`). Always pass a secret. Required unless `config-file` provides it. |
| `smtp-relay-port` | `25` | SMTP relay reachability and greeting (`OCTOMAILTEST_SMTP_RELAY_PORT`). |
| `smtp-port` | `587` | Normal SMTP submission alternative (`OCTOMAILTEST_SMTP_PORT`); TLS is detected automatically. |
| `smtps-port` | `465` | Required SMTPS endpoint (`OCTOMAILTEST_SMTPS_PORT`); TLS is detected automatically. |
| `imap-port` | `143` | Normal IMAP alternative (`OCTOMAILTEST_IMAP_PORT`); TLS is detected automatically. |
| `imaps-port` | `993` | Required IMAPS endpoint (`OCTOMAILTEST_IMAPS_PORT`); TLS is detected automatically. |
| `sieve-port` | `4190` | ManageSieve port (`OCTOMAILTEST_SIEVE_PORT`). Empty or `0` keeps the default. |
| `mode` | `both` | `both`, `mail` or `imap`, like the Docker image command. |
| `config-file` | | Path of an `.octomailtest` file (see `.octomailtest.example`) as an alternative to the inputs above. |
| `quiet` | `false` | Strip the `=====` separator lines, like `--ci`. |
| `private` | `false` | Anonymize identifying values and port numbers in detailed output and reports. Independent of `quiet`. |
| `alias` | `OctoMailTest` | Public target label and history subdirectory; 1–64 letters, digits, underscores, or hyphens, starting with a letter or digit. |
| `history` | `false` | Record timestamped results, cumulative counters, and retained reports locally. |
| `history-keep` | `10` | Positive number of recent runs to retain per alias; cumulative counters are not pruned. |
| `history-dir` | `octomailtest-history` | Safe relative directory beneath the repository, containing one subdirectory per alias. |
| `history-commit` | `false` | With `history: true`, check out the caller and commit/push its updated alias history. Requires a branch run and `contents: write`. |
| `timeout` | `900` | Seconds each diagnostic script may run before it is stopped and reported as a failure. |
| `install-dependencies` | `true` | Install missing tools. Set to `false` on runners that already ship everything. |
| `report-dir` | `octomailtest-report` | Directory (relative to the workspace) that receives the report files. |
| `upload-artifact` | `true` | Upload the report directory as a workflow artifact. |
| `artifact-name` | `octomailtest-report` | Artifact name. Must be unique within a workflow run, so use for example `report-${{ matrix.name }}` in a matrix. |
| `retention-days` | | Artifact retention in days. Empty or `0` uses the repository default. |
| `fail-on-error` | `true` | Fail the job when critical failures are found. |
| `step-summary` | `true` | Write the Markdown summary (with the full report) to the job summary. |
| `annotations` | `true` | Emit an error annotation per critical failure and a warning annotation with the warning count. |

Port inputs are optional; empty values or `0` use their standard defaults.
The inputs win over `OCTOMAILTEST_*` variables set in the job `env`, which
in turn win over values from a config file, matching the precedence of the
scripts themselves.

### Outputs

| Output | Description |
|---|---|
| `status` | `passed` or `failed` |
| `exit-code` | `0` on success, `1` on failures, `124` when a script timed out |
| `failures` | Number of critical failures |
| `warnings` | Number of warnings |
| `report-dir`, `report-file`, `report-json`, `summary-file` | Absolute paths of the report directory and files on the runner |
| `artifact-name`, `artifact-id`, `artifact-url` | Name, id and download page of the uploaded artifact |
| `history-dir`, `history-index` | Absolute paths of the updated alias history directory and its README, when history is enabled |
| `history-count` | Cumulative number of recorded runs for this alias, including reports removed by retention |

```yaml
      - id: mail
        uses: octoleo/octomailtest@master
        with:
          host: mx1.example.com
          email: ${{ secrets.OCTOMAILTEST_EMAIL }}
          pass: ${{ secrets.OCTOMAILTEST_PASS }}
          fail-on-error: false
      - run: echo "Mail check ${{ steps.mail.outputs.status }} with ${{ steps.mail.outputs.failures }} failure(s)"
```

### The report

`report.txt` is the complete output of `mail` and `imap` (exactly what the
Docker image prints), framed by a header with the target, runner and
workflow details and a summary footer with the per-script result and the
failure and warning counts. `report.json` carries the same output plus the
parsed failure and warning messages, the target, timing and workflow
metadata, and `summary.md` is the Markdown shown on the job summary page.
With `private: true`, those reports contain anonymized findings while
preserving the individual test messages and outcomes.

### Good to know

- The action **sends a test email to the mailbox itself through each working
  SMTP alternative** when `swaks` is available (normally two messages when
  both submission endpoints work).
- Without private mode, reports identify the target host and mailbox.
  Enable `private: true` when publishing detailed results from a public
  workflow, and pass all target values through GitHub secrets.
- Both diagnostic scripts report critical failures through a nonzero exit
  status, which the action includes in its result.
- Supported runners: Linux (`ubuntu-latest` is the tested target; Debian,
  Ubuntu, Alpine, Fedora/RHEL, openSUSE and Arch package managers are
  handled) and macOS (Homebrew). Windows runners are not supported.
  Installing tools on a self-hosted runner needs root or passwordless
  `sudo`; otherwise pre-install them and set `install-dependencies: false`.
- Runs take a few minutes; the IMAP protocol tests deliberately pause
  between commands. Unreachable hosts are bounded by the `timeout` input.

---

## Stand-alone usage (no Docker)

Requirements:

* bash
* openssl
* dig
* nc
* swaks
* coreutils

```bash
./mail
./imap
```

Configuration precedence:

1. CLI flags
2. Environment variables
3. `.octomailtest`
4. Defaults

Optional ports have matching CLI, environment, and config names:

| CLI flag | Environment variable | `.octomailtest` key | Default |
|---|---|---|---|
| `--smtp-relay-port` | `OCTOMAILTEST_SMTP_RELAY_PORT` | `SMTP_RELAY_PORT` | `25` |
| `--smtp-port` | `OCTOMAILTEST_SMTP_PORT` | `SMTP_PORT` | `587` |
| `--smtps-port` | `OCTOMAILTEST_SMTPS_PORT` | `SMTPS_PORT` | `465` |
| `--imap-port` | `OCTOMAILTEST_IMAP_PORT` | `IMAP_PORT` | `143` |
| `--imaps-port` | `OCTOMAILTEST_IMAPS_PORT` | `IMAPS_PORT` | `993` |
| `--sieve-port` | `OCTOMAILTEST_SIEVE_PORT` | `SIEVE_PORT` | `4190` |

With the three required credentials already configured, run the mail
diagnostics on all standard ports:

```bash
./src/mail --private --alias Bingo
```

---

## Security notes

* Private mode anonymizes identifying values and port numbers before
  publication, including reports, summaries, and annotations. It does not
  encrypt the reports.
* Treat the public alias, workflow names, and configured report/history
  paths as public labels; do not put identifying values in them.
* The runner still needs the real connection details and credentials to
  perform the tests. Keep those in GitHub secrets or a protected local
  configuration, and use a dedicated test mailbox.
* No mail deletion occurs. The mail diagnostic sends test messages to the
  configured mailbox itself through the working SMTP alternatives when
  `swaks` is available.

---

# Free Software License

```txt
@copyright  Copyright (C) 2021 Llewellyn van der Merwe. All rights reserved.
@license    GNU General Public License version 2; see LICENSE
```

