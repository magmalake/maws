#!/usr/bin/env bash
# Builds a relocatable release tarball: build/dist/maws-<version>-<os>-<arch>.tar.gz
#
#   maws-<version>-<os>-<arch>/
#     bin/maws
#     lib/libKGENCompilerRTShared.*  libMSupportGlobals.*  libAsyncRTRuntimeGlobals.*
#
# Mojo has no static runtime, so the three runtime libraries ship next to the
# binary, found through an rpath relative to it (@executable_path/../lib on
# macOS, $ORIGIN/../lib on Linux) — unpack anywhere, symlink or add bin/ to
# PATH. libcurl is *not* bundled: macOS always has /usr/lib/libcurl.4.dylib,
# and Linux distributions ship libcurl.so.4 (libcurl4 / libcurl).
#
# Run through `pixi run dist`, which provides mojo and $CONDA_PREFIX.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"
version="$(sed -n 's/^comptime VERSION = "\(.*\)"/\1/p' src/main.mojo)"
case "$(uname -s)" in
  Darwin) os=macos; ext=dylib ;;
  Linux) os=linux; ext=so ;;
  *) echo "unsupported OS $(uname -s)" >&2; exit 1 ;;
esac
arch="$(uname -m)"; [ "$arch" = aarch64 ] && arch=arm64; [ "$arch" = x86_64 ] && arch=x64
name="maws-$version-$os-$arch"
stage="build/dist/$name"
rm -rf "$stage" "build/dist/$name.tar.gz"
mkdir -p "$stage/bin" "$stage/lib"

inc=(-I src -I ../sigv4.mojo/src -I ../xml.mojo/src)
if [ "$os" = macos ]; then
  # Link against the SDK's stub of the system libcurl, not conda's.
  sdk="$(xcrun --show-sdk-path)"
  mojo build "${inc[@]}" -Xlinker -L"$sdk/usr/lib" -Xlinker -lcurl \
    -Xlinker -rpath -Xlinker @executable_path/../lib src/main.mojo -o "$stage/bin/maws"
  # mojo also records an absolute rpath into this environment: drop it.
  install_name_tool -delete_rpath "$CONDA_PREFIX/lib" "$stage/bin/maws"
else
  mojo build "${inc[@]}" -Xlinker -L"$CONDA_PREFIX/lib" -Xlinker -lcurl \
    src/main.mojo -o "$stage/bin/maws"
  patchelf --set-rpath '$ORIGIN/../lib' "$stage/bin/maws"
fi

for lib in libKGENCompilerRTShared libMSupportGlobals libAsyncRTRuntimeGlobals; do
  cp -L "$CONDA_PREFIX/lib/$lib.$ext" "$stage/lib/"
done
# Editing load commands invalidates the signature, and arm64 macOS refuses
# to run unsigned code: re-sign ad hoc.
if [ "$os" = macos ]; then
  codesign -f -s - "$stage/lib/"*.dylib "$stage/bin/maws" 2>/dev/null
fi
cp LICENSE NOTICE README.md "$stage/"
tar -C build/dist -czf "build/dist/$name.tar.gz" "$name"
echo "built build/dist/$name.tar.gz ($(du -h "build/dist/$name.tar.gz" | cut -f1))"
