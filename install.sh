#!/bin/sh
# Installs zp on macOS or Linux from an archive that carries its own Node.js.
# The machine needs no Node.js and no npm. The script never uses sudo, and writes only below ~/.zuper.
#
#   curl -fsSL https://raw.githubusercontent.com/ZuperHQ/zp-releases/main/install.sh | sh
#                                                  downloads the newest release, checks it and installs it
#   curl -fsSL <the same address> | sh -s -- --version X.Y.Z
#                                                  the same, for one release
#   sh install.sh [--version X.Y.Z]                the same, from a copy of this script
#   sh install.sh <archive>                        <archive> is a path, or an http(s) URL
#   sh install.sh <archive> --sums <SHA256SUMS>    checks the archive first. <SHA256SUMS> is a path or a URL.
#   sh install.sh --uninstall                      removes zp
#
# A download from the releases is always checked against the SHA256SUMS of the same release.
# A file named SHA256SUMS beside a local archive is used without --sums.
# To update, run the script again. scripts/pack.mjs makes the archives.
set -eu

# The public repo that holds the releases. ZP_RELEASES_URL names another server with the same two paths:
# <url>/latest/download/<file> and <url>/download/vX.Y.Z/<file>. The tests use it.
RELEASES_URL="${ZP_RELEASES_URL:-https://github.com/ZuperHQ/zp-releases/releases}"
ZUPER_HOME="${HOME}/.zuper"
INSTALL_ROOT="${ZUPER_HOME}/zp"
BIN_DIR="${ZUPER_HOME}/bin"
LINK="${BIN_DIR}/zp"
SUMS_NAME="SHA256SUMS"

say() {
	printf '%s\n' "$*"
}

fail() {
	printf 'install.sh: %s\n' "$*" >&2
	exit 1
}

usage() {
	say "Usage: sh install.sh [--version X.Y.Z]"
	say "       sh install.sh <archive path or URL> [--sums <SHA256SUMS path or URL>]"
	say "       sh install.sh --uninstall"
}

# Prints the target of this machine, as the archives name it: darwin-arm64, linux-x64, ...
detect_target() {
	os="$(uname -s)"
	arch="$(uname -m)"
	case "$os" in
		Darwin) os="darwin" ;;
		Linux) os="linux" ;;
		*) fail "This script installs zp on macOS and Linux. This system is ${os}. On Windows, use install.ps1." ;;
	esac
	case "$arch" in
		x86_64 | amd64) arch="x64" ;;
		arm64 | aarch64) arch="arm64" ;;
		*) fail "zp has no archive for the processor ${arch}." ;;
	esac
	# A terminal that runs under Rosetta on an Apple chip says x86_64.
	if [ "$os" = "darwin" ] && [ "$arch" = "x64" ] && [ "$(sysctl -n sysctl.proc_translated 2>/dev/null || true)" = "1" ]; then
		arch="arm64"
	fi
	# The Node.js in the archive needs glibc. Alpine Linux has musl.
	if [ "$os" = "linux" ] && { [ -f /etc/alpine-release ] || (ldd --version 2>&1 || true) | grep -qi musl; }; then
		fail "This Linux uses musl (as Alpine does). The Node.js in the zp archive needs glibc."
	fi
	say "${os}-${arch}"
}

is_url() {
	case "$1" in
		http://* | https://*) return 0 ;;
		*) return 1 ;;
	esac
}

# Prints the address of a file of a release: of the release <version>, or of the newest one when it is empty.
# release_url <version> <file>
release_url() {
	if [ -n "$1" ]; then
		say "${RELEASES_URL}/download/v$1/$2"
	else
		say "${RELEASES_URL}/latest/download/$2"
	fi
}

# download <url> <file>
download() {
	if command -v curl >/dev/null 2>&1; then
		curl -fsSL -o "$2" "$1" || fail "Could not download $1"
	elif command -v wget >/dev/null 2>&1; then
		wget -q -O "$2" "$1" || fail "Could not download $1"
	else
		fail "Downloading needs curl or wget. Neither is installed. Download $1 yourself, and pass the file."
	fi
}

# Prints the sha256 hash of a file, in lower case.
sha256_of() {
	if command -v shasum >/dev/null 2>&1; then
		shasum -a 256 "$1" | awk '{ print tolower($1) }'
	elif command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | awk '{ print tolower($1) }'
	else
		fail "Checking the archive needs shasum or sha256sum. Neither is installed."
	fi
}

# Prints the hash that a sums file gives for a file name. Prints nothing when it has no line for the name.
expected_sum() {
	awk -v name="$2" '{ file = $2; sub(/^\*/, "", file); if (file == name) { print tolower($1); exit } }' "$1"
}

uninstall() {
	if [ ! -e "$INSTALL_ROOT" ] && [ ! -L "$LINK" ]; then
		say "zp is not installed in ${ZUPER_HOME}. Nothing was removed."
		return 0
	fi
	rm -rf "$INSTALL_ROOT"
	rm -f "$LINK"
	rmdir "$BIN_DIR" 2>/dev/null || true
	say "Removed ${INSTALL_ROOT} and ${LINK}."
	say "Your sign-in (${ZUPER_HOME}/credentials.json) and the SDK copy (${ZUPER_HOME}/sdk) stay."
	say "To remove them too: rm -rf \"${ZUPER_HOME}\""
	say "If you added ${BIN_DIR} to PATH in a shell file, delete that line."
}

# Prints the line that puts zp in PATH, and the file it belongs in.
path_help() {
	case ":${PATH}:" in
		*":${BIN_DIR}:"*)
			say "zp is in your PATH. Run: zp --help"
			return 0
			;;
	esac
	case "$(basename "${SHELL:-sh}")" in
		zsh) rc_file=".zshrc" ;;
		bash) if [ "$(uname -s)" = "Darwin" ]; then rc_file=".bash_profile"; else rc_file=".bashrc"; fi ;;
		fish) rc_file="" ;;
		*) rc_file=".profile" ;;
	esac
	say ""
	if [ -z "$rc_file" ]; then
		say "To run zp by its name, run this once:"
		say ""
		say "  fish_add_path \"\$HOME/.zuper/bin\""
	else
		say "To run zp by its name, add this line to ${HOME}/${rc_file}, then open a new terminal:"
		say ""
		say "  export PATH=\"\$HOME/.zuper/bin:\$PATH\""
	fi
	say ""
	say "Until then, run it as: ${LINK}"
}

# The whole install is one function, and the last line of the file calls it. So a script that was cut off
# during "curl ... | sh" runs nothing.
main() {
	archive=""
	sums=""
	wanted_version=""
	do_uninstall=0
	while [ $# -gt 0 ]; do
		case "$1" in
			--uninstall) do_uninstall=1 ;;
			--sums)
				[ $# -ge 2 ] || fail "--sums needs a path or a URL."
				sums="$2"
				shift
				;;
			--sums=*) sums="${1#--sums=}" ;;
			--version)
				[ $# -ge 2 ] || fail "--version needs a version, such as 1.2.3."
				wanted_version="$2"
				shift
				;;
			--version=*) wanted_version="${1#--version=}" ;;
			-h | --help)
				usage
				exit 0
				;;
			-*)
				usage >&2
				fail "Unknown option: $1"
				;;
			*)
				[ -z "$archive" ] || fail "Pass one archive. Got: ${archive} and $1"
				archive="$1"
				;;
		esac
		shift
	done

	if [ "$do_uninstall" -eq 1 ]; then
		uninstall
		exit 0
	fi

	target="$(detect_target)"
	archive_name="zp-${target}.tar.gz"

	# With no archive given, download the one for this machine from the releases, with the SHA256SUMS beside it.
	if [ -z "$archive" ]; then
		# 1.2.3 and v1.2.3 name the same release.
		wanted_version="${wanted_version#v}"
		case "$wanted_version" in
			.* | *[!0-9A-Za-z.-]*) fail "--version needs a version, such as 1.2.3. Got: ${wanted_version}" ;;
		esac
		archive="$(release_url "$wanted_version" "$archive_name")"
		[ -n "$sums" ] || sums="$(release_url "$wanted_version" "$SUMS_NAME")"
	elif [ -n "$wanted_version" ]; then
		fail "--version picks a release to download. Do not pass it with an archive."
	fi

	mkdir -p "$INSTALL_ROOT"
	work="$(mktemp -d "${INSTALL_ROOT}/.install.XXXXXX")"
	trap 'rm -rf "$work"' EXIT
	trap 'exit 1' INT TERM

	# The name that SHA256SUMS lists: the file name, without the query of a URL.
	if is_url "$archive"; then
		listed_name="$(basename "${archive%%\?*}")"
		say "Downloading ${archive}"
		download "$archive" "${work}/${listed_name}"
		archive_file="${work}/${listed_name}"
	else
		[ -f "$archive" ] || fail "${archive} is not a file."
		listed_name="$(basename "$archive")"
		archive_file="$archive"
		if [ -z "$sums" ] && [ -f "$(dirname "$archive")/${SUMS_NAME}" ]; then
			sums="$(dirname "$archive")/${SUMS_NAME}"
		fi
	fi

	if [ -n "$sums" ]; then
		if is_url "$sums"; then
			download "$sums" "${work}/${SUMS_NAME}"
			sums_file="${work}/${SUMS_NAME}"
		else
			[ -f "$sums" ] || fail "${sums} is not a file."
			sums_file="$sums"
		fi
		expected="$(expected_sum "$sums_file" "$listed_name")"
		[ -n "$expected" ] || fail "${sums} has no line for ${listed_name}. Keep the archive's name as it was. Nothing was installed."
		actual="$(sha256_of "$archive_file")"
		if [ "$actual" != "$expected" ]; then
			fail "The sha256 of ${listed_name} is ${actual}. ${sums} says ${expected}. The file is broken or changed. Nothing was installed."
		fi
		say "sha256 ok: ${listed_name} matches ${sums}"
	else
		say "No ${SUMS_NAME} was given, so the archive was not checked."
	fi

	tar -xzf "$archive_file" -C "$work" || fail "Could not unpack ${listed_name}. Is it a zp .tar.gz archive?"
	unpacked="${work}/zp"
	for needed in VERSION TARGET bin/node bin/zp bin/run.js; do
		[ -f "${unpacked}/${needed}" ] || fail "${listed_name} is not a zp archive: it has no zp/${needed}."
	done

	version="$(head -n 1 "${unpacked}/VERSION")"
	case "$version" in
		"" | .* | *[!0-9A-Za-z.-]*) fail "${listed_name} has a version that is not valid: ${version}" ;;
	esac
	archive_target="$(head -n 1 "${unpacked}/TARGET")"
	[ "$archive_target" = "$target" ] || fail "This archive is for ${archive_target}. This machine is ${target}. Take ${archive_name}."

	dest="${INSTALL_ROOT}/${version}"
	rm -rf "$dest"
	mv "$unpacked" "$dest"
	mkdir -p "$BIN_DIR"
	rm -f "$LINK"
	ln -s "${dest}/bin/zp" "$LINK"

	# The check runs zp with only the system folders in PATH, as on a machine with no Node.js.
	printed="$(PATH="/usr/bin:/bin" "$LINK" --version 2>&1)" || fail "zp was unpacked to ${dest}, but it does not start: ${printed}"

	# An update leaves one version in place.
	for other in "$INSTALL_ROOT"/*; do
		[ -d "$other" ] || continue
		[ "$other" = "$dest" ] && continue
		rm -rf "$other"
		say "Removed the older version $(basename "$other")."
	done

	say "Installed zp ${version} in ${dest}"
	say "  ${printed}"
	path_help
}

main "$@"
