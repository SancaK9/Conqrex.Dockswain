#!/usr/bin/env bash
# Build the package and assemble a pacman repo under <repo-root>/public/x86_64/.
# Meant to run inside an archlinux container in CI, but works locally on an Arch
# box too (skip the pacman line if you already have base-devel). Needs $TAG
# (e.g. v0.7.3) and $GITHUB_REPOSITORY (owner/name).
set -euo pipefail

# CI runs this on a bare archlinux image; a local Arch box already has these.
if [ "${SKIP_PACMAN:-0}" != 1 ]; then
    pacman -Syu --noconfirm --needed base-devel git curl
fi

ver="${TAG#v}"
url="https://github.com/${GITHUB_REPOSITORY}/archive/refs/tags/${TAG}.tar.gz"
sum=$(curl -fsSL "$url" | sha256sum | cut -d' ' -f1)

here="$(cd "$(dirname "$0")" && pwd)"
root="$(cd "$here/../.." && pwd)"

cd "$root/packaging/aur"
sed -i "s/^pkgver=.*/pkgver=${ver}/"             PKGBUILD
sed -i "s/^pkgrel=.*/pkgrel=1/"                  PKGBUILD
sed -i "s|^sha256sums=.*|sha256sums=('${sum}')|" PKGBUILD

# makepkg refuses to run as root, so build as an unprivileged user
if [ "$(id -u)" = 0 ]; then
    useradd -m builder 2>/dev/null || true
    chown -R builder "$root/packaging/aur"
    sudo -u builder makepkg -f
else
    makepkg -f
fi

repo_dir="$root/public/x86_64"
mkdir -p "$repo_dir"
cp ./*.pkg.tar.zst "$repo_dir/"

cd "$repo_dir"
repo-add dockswain.db.tar.zst ./*.pkg.tar.zst
# GitHub Pages won't serve the symlinks repo-add creates, so ship real files under
# the names pacman actually fetches (<repo>.db and <repo>.files).
cp -f --remove-destination dockswain.db.tar.zst   dockswain.db
cp -f --remove-destination dockswain.files.tar.zst dockswain.files

echo "Built repo at $repo_dir:"
ls -l "$repo_dir"
