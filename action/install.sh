#!/usr/bin/env bash
#
# OctoMailTest GitHub Action - dependency installer
#
# Makes sure every tool that src/mail and src/imap rely on is available on
# the runner. Only missing tools are installed, so a runner or container
# that already ships everything is left untouched and the step is fast.
#
# Supported package managers:
#   apt-get  Debian / Ubuntu (GitHub-hosted ubuntu-* runners)
#   apk      Alpine
#   dnf/yum  Fedora, RHEL, Rocky, Alma, Amazon Linux
#   zypper   openSUSE
#   pacman   Arch
#   brew     macOS (GitHub-hosted macos-* runners)
#
# Environment:
#   OMT_SWAKS_VERSION  swaks release to download when no package is available
#   GITHUB_PATH        extra bin directories are appended for the later steps

set -euo pipefail

SWAKS_VERSION="${OMT_SWAKS_VERSION:-20240103.0}"

# Hard requirements: need_cmd in src/mail, plus jq for the JSON report.
REQUIRED=(bash openssl dig nc timeout date base64 awk grep sed head jq)
# swaks is optional for the scripts (SMTP AUTH and send tests are skipped
# without it) but the action installs it so the report is complete.
OPTIONAL=(swaks)

#############################################
# Helpers
#############################################

info() { printf '%s\n' "$*"; }
warn() { printf '::warning title=OctoMailTest::%s\n' "$*"; }
die()  { printf '::error title=OctoMailTest::%s\n' "$*" >&2; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }

missing_of() {
	# Print the names from "$@" that are not on PATH, one per line.
	local c
	for c in "$@"; do
		have "$c" || printf '%s\n' "$c"
	done
}

retry() {
	# retry <attempts> <command...>
	local attempts="$1" n=1
	shift
	until "$@"; do
		if (( n >= attempts )); then
			return 1
		fi
		info "Command failed (attempt ${n}/${attempts}), retrying in $((n * 5))s: $*"
		sleep $((n * 5))
		n=$((n + 1))
	done
}

add_path() {
	# Prepend a directory to PATH for this step and for every later step.
	local dir="$1"
	[[ -d "$dir" ]] || return 0
	case ":${PATH}:" in
		*":${dir}:"*) ;;
		*) export PATH="${dir}:${PATH}" ;;
	esac
	if [[ -n "${GITHUB_PATH:-}" ]]; then
		printf '%s\n' "$dir" >> "$GITHUB_PATH"
	fi
}

#############################################
# Platform detection
#############################################

OS="${RUNNER_OS:-$(uname -s)}"
case "$OS" in
	Linux|linux) OS=Linux ;;
	macOS|Darwin) OS=macOS ;;
	*)
		die "Unsupported runner OS '${OS}'. OctoMailTest needs a Linux or macOS runner (dig, nc, swaks and GNU coreutils are not available on Windows runners)."
		;;
esac

PM=""
if [[ "$OS" == Linux ]]; then
	for candidate in apt-get apk dnf yum zypper pacman; do
		if have "$candidate"; then
			PM="$candidate"
			break
		fi
	done
elif have brew; then
	PM=brew
fi

# Privilege escalation for system package managers (never for Homebrew).
SUDO=()
NO_ROOT=0
if [[ -n "$PM" && "$PM" != brew && "$(id -u)" -ne 0 ]]; then
	if have sudo && sudo -n true 2>/dev/null; then
		SUDO=(sudo -n)
	else
		PM=""
		NO_ROOT=1
	fi
fi

#############################################
# Package names per package manager
#############################################

packages_for() {
	# packages_for <command> -> package name(s) that provide it under $PM
	local cmd="$1"
	case "$PM" in
		apt-get)
			case "$cmd" in
				dig) echo dnsutils ;;
				nc) echo netcat-openbsd ;;
				timeout|date|base64|head) echo coreutils ;;
				awk) echo gawk ;;
				swaks) echo swaks libnet-ssleay-perl ;;
				*) echo "$cmd" ;;
			esac
			;;
		apk)
			case "$cmd" in
				dig) echo bind-tools ;;
				nc) echo netcat-openbsd ;;
				timeout|date|base64|head) echo coreutils ;;
				awk) echo gawk ;;
				swaks) echo swaks perl-net-ssleay ;;
				*) echo "$cmd" ;;
			esac
			;;
		dnf|yum)
			case "$cmd" in
				dig) echo bind-utils ;;
				nc) echo netcat ;;
				timeout|date|base64|head) echo coreutils ;;
				awk) echo gawk ;;
				swaks) echo swaks perl-Net-SSLeay ;;
				*) echo "$cmd" ;;
			esac
			;;
		zypper)
			case "$cmd" in
				dig) echo bind-utils ;;
				nc) echo netcat-openbsd ;;
				timeout|date|base64|head) echo coreutils ;;
				awk) echo gawk ;;
				swaks) echo swaks perl-Net-SSLeay ;;
				*) echo "$cmd" ;;
			esac
			;;
		pacman)
			case "$cmd" in
				dig) echo bind ;;
				nc) echo openbsd-netcat ;;
				timeout|date|base64|head) echo coreutils ;;
				awk) echo gawk ;;
				swaks) echo perl perl-net-ssleay ;;   # swaks itself is AUR-only: downloaded below
				*) echo "$cmd" ;;
			esac
			;;
		brew)
			case "$cmd" in
				openssl) echo openssl@3 ;;
				dig) echo bind ;;
				nc) echo netcat ;;
				timeout|date|base64|head) echo coreutils ;;
				awk) echo gawk ;;
				sed) echo gnu-sed ;;
				*) echo "$cmd" ;;
			esac
			;;
	esac
}

alternatives_for() {
	# alternatives_for <command> -> fallback package(s) when packages_for failed
	local cmd="$1"
	case "$PM:$cmd" in
		dnf:nc|yum:nc) echo nmap-ncat ;;
		apt-get:nc) echo netcat-traditional ;;
		apt-get:dig) echo bind9-dnsutils ;;
		*) ;;
	esac
}

#############################################
# Package manager drivers
#############################################

PM_REFRESHED=0

pm_refresh() {
	# Refresh the package index once, only when something has to be installed.
	(( PM_REFRESHED == 0 )) || return 0
	PM_REFRESHED=1
	case "$PM" in
		apt-get)
			retry 3 ${SUDO[@]+"${SUDO[@]}"} apt-get -q update \
				|| warn "apt-get update reported errors; installing with the existing package index."
			;;
		pacman)
			retry 3 ${SUDO[@]+"${SUDO[@]}"} pacman -Sy --noconfirm || true
			;;
	esac
}

pm_install() {
	# pm_install <package...>
	[[ $# -gt 0 ]] || return 0
	info "Installing with ${PM}: $*"
	case "$PM" in
		apt-get)
			retry 3 ${SUDO[@]+"${SUDO[@]}"} env DEBIAN_FRONTEND=noninteractive \
				apt-get -y -q -o Dpkg::Use-Pty=0 --no-install-recommends install "$@"
			;;
		apk)    retry 3 ${SUDO[@]+"${SUDO[@]}"} apk add --no-cache "$@" ;;
		dnf)    retry 3 ${SUDO[@]+"${SUDO[@]}"} dnf install -y "$@" ;;
		yum)    retry 3 ${SUDO[@]+"${SUDO[@]}"} yum install -y "$@" ;;
		zypper) retry 3 ${SUDO[@]+"${SUDO[@]}"} zypper --non-interactive install "$@" ;;
		pacman) retry 3 ${SUDO[@]+"${SUDO[@]}"} pacman -S --noconfirm --needed "$@" ;;
		brew)   HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1 retry 3 brew install "$@" ;;
		*)      return 1 ;;
	esac
}

install_command() {
	# install_command <command>: install the package(s) providing <command>,
	# trying the alternatives when the first choice is not available.
	local cmd="$1" pkgs alts
	pkgs="$(packages_for "$cmd")"
	alts="$(alternatives_for "$cmd")"
	pm_refresh
	# shellcheck disable=SC2086  # package lists are intentionally word-split
	if pm_install $pkgs && have "$cmd"; then
		return 0
	fi
	if [[ -n "$alts" ]]; then
		info "Package(s) '${pkgs}' did not provide '${cmd}', trying '${alts}'"
		# shellcheck disable=SC2086
		pm_install $alts || true
	fi
	have "$cmd"
}

#############################################
# swaks (optional, but needed for SMTP AUTH and send tests)
#############################################

download_swaks() {
	# Fall back to the upstream script when no package is available.
	local dir="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/octomailtest-bin" url
	if ! have curl; then
		warn "curl is not available, cannot download swaks."
		return 1
	fi
	if ! have perl; then
		if [[ -n "$PM" ]]; then
			pm_install perl || true
		fi
		if ! have perl; then
			warn "perl is not available, cannot use the downloaded swaks."
			return 1
		fi
	fi
	mkdir -p "$dir"
	for url in \
		"https://jetmore.org/john/code/swaks/files/swaks-${SWAKS_VERSION}/swaks" \
		"https://raw.githubusercontent.com/jetmore/swaks/v${SWAKS_VERSION}/swaks"
	do
		info "Downloading swaks ${SWAKS_VERSION} from ${url}"
		if curl -fsSL --retry 3 --connect-timeout 20 --max-time 120 -o "${dir}/swaks" "$url" \
			&& head -n 1 "${dir}/swaks" | grep -q perl; then
			chmod +x "${dir}/swaks"
			add_path "$dir"
			return 0
		fi
	done
	rm -f "${dir}/swaks"
	return 1
}

install_swaks() {
	have swaks && return 0
	if [[ -n "$PM" ]]; then
		local -a swaks_pkgs=()
		read -r -a swaks_pkgs <<< "$(packages_for swaks)"
		pm_refresh
		pm_install "${swaks_pkgs[@]}" || true
		have swaks && return 0
		case "$PM" in
			apk)
				info "swaks is not in the enabled Alpine repositories, trying edge/testing"
				${SUDO[@]+"${SUDO[@]}"} apk add --no-cache \
					--repository=https://dl-cdn.alpinelinux.org/alpine/edge/testing swaks || true
				;;
			dnf|yum)
				info "swaks is not in the enabled repositories, trying EPEL"
				if pm_install epel-release; then
					pm_install swaks perl-Net-SSLeay || true
				fi
				;;
		esac
		have swaks && return 0
	fi
	download_swaks
}

#############################################
# Install what is missing
#############################################

info "Runner: ${OS} ${RUNNER_ARCH:-$(uname -m)}, package manager: ${PM:-none}"

MISSING_REQUIRED=()
while IFS= read -r c; do
	MISSING_REQUIRED+=("$c")
done < <(missing_of "${REQUIRED[@]}")

if (( ${#MISSING_REQUIRED[@]} == 0 )) && have swaks; then
	info "All OctoMailTest tools are already installed, nothing to do."
else
	if (( ${#MISSING_REQUIRED[@]} > 0 )); then
		if [[ -z "$PM" ]]; then
			if (( NO_ROOT )); then
				die "Tools missing (${MISSING_REQUIRED[*]}) and no root or passwordless sudo to install them. Run the job as root, pre-install the tools in your image, or set install-dependencies: false after installing them yourself."
			fi
			die "Tools missing (${MISSING_REQUIRED[*]}) and no supported package manager (apt-get, apk, dnf, yum, zypper, pacman, brew) was found."
		fi
		info "Missing tools: ${MISSING_REQUIRED[*]}"
		for c in "${MISSING_REQUIRED[@]}"; do
			install_command "$c" || warn "Could not install a package providing '${c}'."
		done
	fi

	if ! have swaks; then
		install_swaks || true
	fi

	if [[ "$PM" == brew ]]; then
		# Prefer the GNU tools (timeout, date, base64, head, grep, sed) and
		# OpenSSL 3 over the BSD/LibreSSL versions that ship with macOS.
		BREW_PREFIX="$(brew --prefix)"
		add_path "${BREW_PREFIX}/opt/coreutils/libexec/gnubin"
		add_path "${BREW_PREFIX}/opt/grep/libexec/gnubin"
		add_path "${BREW_PREFIX}/opt/gnu-sed/libexec/gnubin"
		add_path "${BREW_PREFIX}/opt/openssl@3/bin"
	fi
fi

#############################################
# Verify
#############################################

STILL_MISSING=()
while IFS= read -r c; do
	STILL_MISSING+=("$c")
done < <(missing_of "${REQUIRED[@]}")

echo "::group::OctoMailTest tools"
for c in "${REQUIRED[@]}" "${OPTIONAL[@]}"; do
	if have "$c"; then
		printf '  ok       %-8s %s\n' "$c" "$(command -v "$c")"
	else
		printf '  MISSING  %-8s\n' "$c"
	fi
done
printf '\n'
have openssl && openssl version
have dig && dig -v 2>&1 | head -n 1
have nc && { nc -h 2>&1 | head -n 1 || true; }
have timeout && timeout --version 2>&1 | head -n 1
have jq && jq --version
have swaks && swaks --version 2>&1 | head -n 1
echo "::endgroup::"

if (( ${#STILL_MISSING[@]} > 0 )); then
	die "Required tools are still missing after installation: ${STILL_MISSING[*]}"
fi

if have nc && nc -h 2>&1 | grep -qi 'ncat'; then
	warn "Nmap ncat provides 'nc' on this runner. OctoMailTest expects OpenBSD or GNU netcat output for its port checks, so ports may be reported as blocked. Install netcat-openbsd if possible."
fi

if have swaks; then
	if have perl && ! perl -MNet::SSLeay -e 1 2>/dev/null; then
		warn "swaks is installed but the Perl module Net::SSLeay is missing, so its TLS tests (--tls) will fail. Install libnet-ssleay-perl / perl-Net-SSLeay on the runner."
	fi
else
	warn "swaks could not be installed. The SMTP AUTH and send-to-self tests will be skipped in the report."
fi

info "OctoMailTest dependencies are ready."
