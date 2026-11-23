#!/usr/bin/env bash
# Usage: install-gut.sh <godot-project-dir> <gut-tag> <sha256 of the tag's GitHub source tarball>
# Installs GUT into <project>/addons/gut unless the project already vendors it.
# GUT publishes no release assets or checksums, so the tarball hash is computed and pinned in ci.yml.
set -euo pipefail
proj="$1"
tag="$2"
sha256="$3"
if [ -f "${proj}/addons/gut/gut_cmdln.gd" ]; then
  echo "GUT already vendored at ${proj}/addons/gut ($(grep -m1 '^version' "${proj}/addons/gut/plugin.cfg" || echo 'version unknown'))"
  exit 0
fi
tmp="$(mktemp -d)"
curl -fsSL --retry 3 -o "${tmp}/gut.tar.gz" "https://github.com/bitwes/Gut/archive/refs/tags/${tag}.tar.gz"
echo "${sha256}  ${tmp}/gut.tar.gz" | sha256sum -c -
tar -xzf "${tmp}/gut.tar.gz" -C "$tmp"
src="$(find "$tmp" -maxdepth 3 -type d -path '*/addons/gut' | head -n1)"
[ -n "$src" ] || { echo "::error::GUT ${tag} archive has no addons/gut"; exit 1; }
mkdir -p "${proj}/addons"
cp -a "$src" "${proj}/addons/gut"
rm -rf "$tmp"
echo "Installed GUT ${tag} into ${proj}/addons/gut"
