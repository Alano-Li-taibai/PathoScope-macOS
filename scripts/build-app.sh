#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
output_dir="${1:-$repo_root/dist}"
app_path="$output_dir/PathoScope.app"

swift build --package-path "$repo_root" -c release
bin_dir="$(swift build --package-path "$repo_root" -c release --show-bin-path)"

mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
cp "$bin_dir/PathoScopeApp" "$app_path/Contents/MacOS/PathoScopeApp"
cp "$repo_root/Packaging/Info.plist" "$app_path/Contents/Info.plist"
cp "$repo_root/Packaging/PathoScope.icns" "$app_path/Contents/Resources/PathoScope.icns"

brew_cmd=""
if [[ "$(uname -m)" == "arm64" && -x /opt/homebrew/bin/brew ]]; then
  brew_cmd="/opt/homebrew/bin/brew"
elif [[ -x /usr/local/bin/brew ]]; then
  brew_cmd="/usr/local/bin/brew"
elif command -v brew >/dev/null 2>&1; then
  brew_cmd="$(command -v brew)"
fi

if [[ -n "$brew_cmd" ]] && "$brew_cmd" --prefix openslide >/dev/null 2>&1; then
  brew_prefix="$("$brew_cmd" --prefix)"
  openslide_prefix="$("$brew_cmd" --prefix openslide)"
  pkg_config="$brew_prefix/bin/pkg-config"
  if [[ ! -x "$pkg_config" ]]; then
    pkg_config="$(command -v pkg-config)"
  fi
  openslide_flag_text="$(env -u PKG_CONFIG_PATH -u PKG_CONFIG_LIBDIR "$pkg_config" --cflags --libs openslide)"
  read -r -a openslide_flags <<< "$openslide_flag_text"
  clang "$repo_root/Tools/OpenSlideTileHelper/main.c" \
    -o "$app_path/Contents/Resources/openslide-tile-helper" \
    "${openslide_flags[@]}"
  chmod +x "$app_path/Contents/Resources/openslide-tile-helper"
  echo "OpenSlide helper built for $(uname -m)."
else
  echo "OpenSlide not found; building MRXS-only app. Install it with: brew install openslide" >&2
fi

codesign --force --deep --sign - "$app_path"
codesign --verify --deep --strict --verbose=2 "$app_path"
echo "Built: $app_path"
