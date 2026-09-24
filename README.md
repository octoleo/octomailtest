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
- SMTP (25, 465, 587)
- IMAPS (993)
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

No mail data is modified unless you explicitly allow the send test.

---

## Environment variables

All configuration is driven by `OCTOMAILTEST_*`

```bash
OCTOMAILTEST_DOMAIN=email.com
OCTOMAILTEST_HOST=mx1.email.host
OCTOMAILTEST_EMAIL=your@email.com
OCTOMAILTEST_PASS=secret

OCTOMAILTEST_IMAP_PORT=993
OCTOMAILTEST_SMTP_PORT=587
OCTOMAILTEST_SIEVE_PORT=4190
````

You may also place these in `.octomailtest`.

---

## Docker usage

### Run everything (default)

```bash
docker run --rm \
  -e OCTOMAILTEST_DOMAIN=email.com \
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
          domain: example.com
          host: mx1.example.com
          email: ${{ secrets.OCTOMAILTEST_EMAIL }}
          pass: ${{ secrets.OCTOMAILTEST_PASS }}
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
      domain: example.com
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
`retention-days`, `runs-on`) and exposes `status`, `exit-code`, `failures`,
`warnings`, `artifact-name` and `artifact-url` as outputs.

In this repository the workflow also runs on every pull request and push to
`master` (using the repository's `OCTOMAILTEST_*` secrets) and can be
started manually from the **Actions** tab.

### Inputs

| Input | Default | Description |
|---|---|---|
| `domain` | | Mail domain for the DNS checks (`OCTOMAILTEST_DOMAIN`). DNS checks are skipped without it. |
| `host` | | Mail server host (`OCTOMAILTEST_HOST`). Required unless `config-file` provides it. |
| `email` | | Mailbox address (`OCTOMAILTEST_EMAIL`). Required unless `config-file` provides it. |
| `pass` | | Mailbox password (`OCTOMAILTEST_PASS`). Always pass a secret. Required unless `config-file` provides it. |
| `imap-port` | `993` | IMAPS port (`OCTOMAILTEST_IMAP_PORT`). Empty or `0` keeps the default. |
| `smtp-port` | `587` | SMTP submission port (`OCTOMAILTEST_SMTP_PORT`). Empty or `0` keeps the default. |
| `sieve-port` | `4190` | ManageSieve port (`OCTOMAILTEST_SIEVE_PORT`). Empty or `0` keeps the default. |
| `mode` | `both` | `both`, `mail` or `imap`, like the Docker image command. |
| `config-file` | | Path of an `.octomailtest` file (see `.octomailtest.example`) as an alternative to the inputs above. |
| `quiet` | `false` | Strip the `=====` separator lines, like `--ci`. |
| `timeout` | `900` | Seconds each diagnostic script may run before it is stopped and reported as a failure. |
| `install-dependencies` | `true` | Install missing tools. Set to `false` on runners that already ship everything. |
| `report-dir` | `octomailtest-report` | Directory (relative to the workspace) that receives the report files. |
| `upload-artifact` | `true` | Upload the report directory as a workflow artifact. |
| `artifact-name` | `octomailtest-report` | Artifact name. Must be unique within a workflow run, so use for example `report-${{ matrix.name }}` in a matrix. |
| `retention-days` | | Artifact retention in days. Empty or `0` uses the repository default. |
| `fail-on-error` | `true` | Fail the job when critical failures are found. |
| `step-summary` | `true` | Write the Markdown summary (with the full report) to the job summary. |
| `annotations` | `true` | Emit an error annotation per critical failure and a warning annotation with the warning count. |

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

### Good to know

- Like every OctoMailTest run, the action **sends one test email to the
  mailbox itself** as part of the SMTP send test when `swaks` is available.
- The password is masked in the workflow log and scrubbed from the report
  files before they are uploaded. Still, treat the artifact as internal:
  it names the host and the mailbox.
- `src/imap` is informational and never fails by itself; `src/mail` decides
  the pass/fail result.
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

---

## Security notes

* Passwords are never logged in clear text
* TLS verification is enforced
* No mail deletion occurs
* All send tests are explicit

---

# Free Software License

```txt
@copyright  Copyright (C) 2021 Llewellyn van der Merwe. All rights reserved.
@license    GNU General Public License version 2; see LICENSE
```

