#!/usr/bin/env bash
# FuntiDesk for Linux x86_64: build the client and pack funtidesk-<version>-x86_64.deb.
#
# The steps follow the upstream Linux CI job (client/.github/workflows/flutter-build.yml,
# build-rustdesk-linux) and the Windows baseline (scripts/windows/build-baseline.ps1):
# the same Rust 1.75, flutter_rust_bridge 1.80.1, Flutter 3.22.3 for the bridge and
# 3.24.5 with the upstream patch for the build, the same vcpkg commit. Packaging is our
# own: binary, service, paths and desktop files are named funtidesk (src/platform/linux.rs
# manages the unit by the lowercased app name), from client/res/funtidesk-linux.
#
# Environment: VCPKG_ROOT with `vcpkg install --triplet x64-linux` done in client/,
# FLUTTER_BRIDGE and FLUTTER_BUILD pointing at the two Flutter SDKs.
set -euo pipefail

repo="$(cd "$(dirname "$0")/../.." && pwd)"
client="$repo/client"
: "${VCPKG_ROOT:?VCPKG_ROOT is not set}"
: "${FLUTTER_BRIDGE:?FLUTTER_BRIDGE is not set}"
: "${FLUTTER_BUILD:?FLUTTER_BUILD is not set}"
export VCPKG_ROOT
export RUSTUP_TOOLCHAIN=1.75.0

for sdk in "$FLUTTER_BRIDGE:b0850beeb25f6d5b10426284f506557f66181b36" \
           "$FLUTTER_BUILD:dec2ee5c1f98f8e84a7d5380c05eb8a3d0a81668"; do
  dir="${sdk%%:*}"
  want="${sdk##*:}"
  got="$(git -C "$dir" rev-parse HEAD)"
  [ "$got" = "$want" ] || { echo "Flutter at $dir is $got, expected $want" >&2; exit 1; }
done

version="$(sed -n 's/^version = "\(.*\)"/\1/p' "$client/Cargo.toml" | head -1)-ft.$(git -C "$repo" rev-list --count HEAD)"
echo "FuntiDesk $version"
cd "$client"

echo '== flutter_rust_bridge =='
cargo install cargo-expand --version 1.0.95 --locked
cargo install flutter_rust_bridge_codegen --version 1.80.1 --features uuid --locked
cp flutter/pubspec.yaml /tmp/funtidesk-pubspec.yaml
cp flutter/pubspec.lock /tmp/funtidesk-pubspec.lock
restore_pubspec() {
  cp /tmp/funtidesk-pubspec.yaml flutter/pubspec.yaml
  cp /tmp/funtidesk-pubspec.lock flutter/pubspec.lock
}
trap restore_pubspec EXIT
sed -i 's/extended_text: 14.0.0/extended_text: 13.0.0/' flutter/pubspec.yaml
(cd flutter && "$FLUTTER_BRIDGE/bin/flutter" pub get)
"$HOME/.cargo/bin/flutter_rust_bridge_codegen" --rust-input ./src/flutter_ffi.rs \
  --dart-output ./flutter/lib/generated_bridge.dart \
  --c-output ./flutter/macos/Runner/bridge_generated.h
restore_pubspec
trap - EXIT

echo '== Rust =='
cargo build --locked --lib --release --features hwcodec,flutter,unix-file-copy-paste
# Same workaround as build.py ffi_bindgen_function_refactor().
sed -i 's/ffi.NativeFunction<ffi.Bool Function(DartPort/ffi.NativeFunction<ffi.Uint8 Function(DartPort/g' \
  flutter/lib/generated_bridge.dart

echo '== Flutter =='
patch="$client/.github/patches/flutter_3.24.4_dropdown_menu_enableFilter.diff"
if git -C "$FLUTTER_BUILD" apply --check "$patch" 2>/dev/null; then
  git -C "$FLUTTER_BUILD" apply "$patch"
else
  git -C "$FLUTTER_BUILD" apply --reverse --check "$patch"
fi
(cd flutter && "$FLUTTER_BUILD/bin/flutter" config --enable-linux-desktop \
  && "$FLUTTER_BUILD/bin/flutter" build linux --release)

echo '== deb =='
res="$client/res/funtidesk-linux"
pkg="$(mktemp -d)"
share="$pkg/usr/share/funtidesk"
mkdir -p "$share/files/systemd" "$pkg/usr/share/applications" \
  "$pkg/usr/share/icons/hicolor/256x256/apps" "$pkg/usr/share/icons/hicolor/scalable/apps" \
  "$pkg/DEBIAN"
cp -r flutter/build/linux/x64/release/bundle/* "$share/"
test -x "$share/funtidesk" && test -f "$share/lib/librustdesk.so"
cp "$res/funtidesk.service" "$share/files/systemd/"
cp "$res/funtidesk.desktop" "$res/funtidesk-link.desktop" "$pkg/usr/share/applications/"
cp res/128x128@2x.png "$pkg/usr/share/icons/hicolor/256x256/apps/funtidesk.png"
cp res/scalable.svg "$pkg/usr/share/icons/hicolor/scalable/apps/funtidesk.svg"
cp "$res"/DEBIAN/* "$pkg/DEBIAN/"
cat > "$pkg/DEBIAN/control" <<EOF
Package: funtidesk
Section: net
Priority: optional
Version: $version
Architecture: amd64
Maintainer: FuntiDesk <https://github.com/michailr1/FuntiDesk>
Homepage: https://desk.funti.cc
Depends: libgtk-3-0t64 | libgtk-3-0, libxcb-randr0, libxdo3 | libxdo4, libxfixes3, libxcb-shape0, libxcb-xfixes0, libasound2t64 | libasound2, libsystemd0, curl, libva2, libva-drm2, libva-x11-2, libgstreamer-plugins-base1.0-0, gstreamer1.0-pipewire
Recommends: libayatana-appindicator3-1
Description: FuntiDesk remote access for family and friends.
EOF
(cd "$pkg" && find usr -type f -exec md5sum {} + > DEBIAN/md5sums)
out="$repo/funtidesk-$version-x86_64.deb"
dpkg-deb --root-owner-group -b "$pkg" "$out"
rm -rf "$pkg"
dpkg-deb -I "$out"
echo "DEB=$out"
