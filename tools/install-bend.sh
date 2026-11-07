#!/bin/sh
# Installs the pinned Bend for Linux into ~/.bend, checking the archive's
# sha256. bend-kube needs exactly this version: Bend's C effect interface
# has no ABI promise, so upgrades go through CI (tools/ci.sh checks it).
set -eu
BEND_VERSION=${BEND_VERSION:-2.0.40}
BEND_SHA_ARM64=${BEND_SHA_ARM64:-2f42a6fa34ecdaa71ae105e5fa734f9a07e129d333e45448ab6d2ff03a837570}
BEND_SHA_X64=${BEND_SHA_X64:-c9ff8d67bd903fb6ad9a26b43d8a62c01021de82a44d55ce4a3dcd4732113d6b}
case "$(uname -m)" in
  aarch64|arm64) arch=arm64; sum=$BEND_SHA_ARM64;;
  x86_64|amd64) arch=x64; sum=$BEND_SHA_X64;;
  *) echo "unsupported arch $(uname -m)"; exit 1;;
esac
name="bend-$BEND_VERSION-linux-$arch.tar.gz"
tmp=$(mktemp -d)
curl --proto '=https' --tlsv1.2 -fsSL -o "$tmp/$name" \
  "https://github.com/bendlang/bend/releases/download/v$BEND_VERSION/$name"
echo "$sum  $tmp/$name" | sha256sum -c -
mkdir -p "$HOME/.bend"
tar -xzf "$tmp/$name" -C "$HOME/.bend" --strip-components=1 2>/dev/null \
  || tar -xzf "$tmp/$name" -C "$HOME/.bend"
rm -rf "$tmp"
