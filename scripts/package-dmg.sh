#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
release_dir="${1:-$repo_root/dist}"
version="v0.4.1-build8"
work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

"$repo_root/scripts/build-app.sh" "$work_dir/app"
mkdir -p "$work_dir/dmg"
cp -R "$work_dir/app/PathoScope.app" "$work_dir/dmg/PathoScope.app"
ln -s /Applications "$work_dir/dmg/Applications"
cp "$repo_root/INSTALL.md" "$work_dir/dmg/安装说明.md"

mkdir -p "$release_dir"
release_dir="$(cd "$release_dir" && pwd)"
dmg_path="$release_dir/PathoScope-$version-AppleSilicon.dmg"
hdiutil create -volname "PathoScope $version" -srcfolder "$work_dir/dmg" -ov -format UDZO "$dmg_path"
(cd "$release_dir" && shasum -a 256 "$(basename "$dmg_path")" > "$(basename "$dmg_path").sha256")
echo "Packaged: $dmg_path"
