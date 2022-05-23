<h2><img align="middle" src="https://raw.githubusercontent.com/odb/official-bash-logo/master/assets/Logos/Icons/PNG/64x64.png" >
OctoMailTest - Automated Email testing suite
</h2>

Written by Llewellyn van der Merwe (@llewellynvdm)

**OctoMailTest** is a deep diagnostic tool for validating mail infrastructure:
SMTP, IMAP, TLS, DNS, Sieve, authentication, and deliverability.

It can be run:
- as a **stand-alone Bash tool**
- or as a **minimal Docker container**

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

