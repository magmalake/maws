#!/usr/bin/env bash
# Install maws from a GitHub release.
#
#   curl -fsSL https://raw.githubusercontent.com/magmalake/maws/main/install.sh | bash
#
# Read this script before piping it to a shell. It is short, and all it does:
#
#   1. picks the tarball for this machine (macOS arm64 or Linux x64);
#   2. resolves the version: $MAWS_VERSION, else the latest release, found by
#      following GitHub's /releases/latest redirect (no API token, no rate limit);
#   3. downloads the tarball and its .sha256 from that release and refuses to
#      go on unless the checksum matches;
#   4. unpacks it to ~/.local/share/maws/<version>/ and symlinks
#      ~/.local/bin/maws to it, replacing an earlier link.
#
# No sudo, nothing outside those two directories, nothing run from the
# download besides `maws --version` at the end. Settings, all optional:
#
#   MAWS_VERSION=0.1.1        a specific release instead of the latest
#   MAWS_HOME=~/.local/share/maws   where versions are unpacked
#   MAWS_BIN_DIR=~/.local/bin       where the `maws` link goes
#
# Uninstall: rm -rf ~/.local/share/maws ~/.local/bin/maws

set -euo pipefail

repo="magmalake/maws"
release_base="${MAWS_RELEASE_BASE:-https://github.com/$repo/releases/download}"
home="${MAWS_HOME:-$HOME/.local/share/maws}"
bin_dir="${MAWS_BIN_DIR:-$HOME/.local/bin}"

say() { printf 'maws-install: %s\n' "$*"; }
die() { printf 'maws-install: error: %s\n' "$*" >&2; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || die "needs '$1' on PATH"; }
need curl
need tar
need uname

# Wrapped in a function and called on the last line, so a download cut off
# halfway through can never run a partial script.
main() {
  local os arch platform
  os="$(uname -s)"
  arch="$(uname -m)"
  case "$os/$arch" in
    Darwin/arm64) platform=macos-arm64 ;;
    Linux/x86_64) platform=linux-x64 ;;
    *) die "no prebuilt maws for $os/$arch (macOS arm64 and Linux x64 only); build from source: https://github.com/$repo#from-source" ;;
  esac

  if [ "$platform" = linux-x64 ] && command -v ldconfig >/dev/null 2>&1 \
     && ! ldconfig -p 2>/dev/null | grep -q 'libcurl\.so\.4'; then
    say "warning: libcurl.so.4 not found; install libcurl4 (Debian/Ubuntu) or libcurl (Fedora/Arch)"
  fi

  local version="${MAWS_VERSION:-}"
  if [ -z "$version" ]; then
    local url
    url="$(curl -fsSLI -o /dev/null -w '%{url_effective}' "https://github.com/$repo/releases/latest")" \
      || die "could not reach github.com to find the latest release"
    version="${url##*/tag/v}"
    [ "$version" != "$url" ] && [ -n "$version" ] || die "could not find the latest release (got $url)"
  fi
  version="${version#v}"

  local name="maws-$version-$platform"
  local tarball="$name.tar.gz"
  # Global, not local: the EXIT trap runs after main has returned.
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT

  say "downloading maws $version for $platform"
  curl -fsSL -o "$tmp/$tarball" "$release_base/v$version/$tarball" \
    || die "download failed: $release_base/v$version/$tarball"
  curl -fsSL -o "$tmp/$tarball.sha256" "$release_base/v$version/$tarball.sha256" \
    || die "no checksum published for $tarball; refusing to install it unverified"

  local want got
  want="$(awk '{print $1; exit}' "$tmp/$tarball.sha256")"
  if command -v shasum >/dev/null 2>&1; then
    got="$(shasum -a 256 "$tmp/$tarball" | awk '{print $1}')"
  elif command -v sha256sum >/dev/null 2>&1; then
    got="$(sha256sum "$tmp/$tarball" | awk '{print $1}')"
  else
    die "needs shasum or sha256sum to verify the download"
  fi
  [ -n "$want" ] && [ "$want" = "$got" ] \
    || die "checksum mismatch for $tarball (expected $want, got $got)"
  say "checksum ok ($got)"

  # Unpack beside the final location, then move into place, so an
  # interrupted install never leaves a half-written version directory.
  mkdir -p "$home" "$bin_dir"
  tar -C "$tmp" -xzf "$tmp/$tarball"
  [ -x "$tmp/$name/bin/maws" ] || die "unexpected tarball layout: no $name/bin/maws"
  rm -rf "${home:?}/$version"
  mv "$tmp/$name" "$home/$version"
  ln -sfn "$home/$version/bin/maws" "$bin_dir/maws"

  say "installed $bin_dir/maws -> $home/$version/bin/maws"
  "$bin_dir/maws" --version || die "the installed binary did not run"

  case ":$PATH:" in
    *":$bin_dir:"*) ;;
    *) say "note: $bin_dir is not on your PATH; add it, e.g. echo 'export PATH=\"$bin_dir:\$PATH\"' >> ~/.zshrc" ;;
  esac
}

main "$@"
