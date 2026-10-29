#!/bin/sh
# Installs the pinned Bend for Linux into ~/.bend, checking the archive's
# sha256. bend-kube needs exactly this version: Bend's C effect interface
# has no ABI promise, so upgrades go through CI (tools/ci.sh checks it).
set -eu
BEND_VERSION=${BEND_VERSION:-2.0.39}
BEND_SHA_ARM64=${BEND_SHA_ARM64:-71b43e1bb9313dd14ac2b0553b854e41c39d65ecaa47040796ebff4a46f54a97}
BEND_SHA_X64=${BEND_SHA_X64:-6cf462fd8f70b094a4950ebb709a9c4ffd8f1d1189d9cedf1fd63cd5d041c7ab}
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
