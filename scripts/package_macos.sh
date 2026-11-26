#!/bin/bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
project_dir="$(cd -- "$script_dir/.." && pwd)"
cd "$project_dir"

lock_before="$(shasum -a 256 pubspec.lock)"
flutter pub get --offline --enforce-lockfile
flutter analyze --no-pub
flutter test --no-pub --reporter expanded
flutter build macos --release --no-pub
lock_after="$(shasum -a 256 pubspec.lock)"
if [[ "$lock_before" != "$lock_after" ]]; then
  printf '%s\n' 'Lock file changed; packaging stopped.' >&2
  exit 1
fi

app_path="$project_dir/build/macos/Build/Products/Release/LAN APK Sync.app"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_path/Contents/Info.plist")"
executable="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$app_path/Contents/Info.plist")"
architectures="$(lipo -archs "$app_path/Contents/MacOS/$executable")"
codesign --verify --deep --strict "$app_path"

mkdir -p "$project_dir/dist"
stage_dir="$(mktemp -d "$project_dir/dist/LAN-APK-Sync-$version.XXXXXX")"
ditto --norsrc --noextattr --noqtn "$app_path" "$stage_dir/LAN APK Sync.app"
cp "$project_dir/docs/OFFLINE.md" "$stage_dir/使用说明.md"
cp "$project_dir/docs/ANDROID.md" "$stage_dir/ANDROID.md"
printf 'Version: %s\nArchitectures: %s\nMinimum macOS: 10.15\n' \
  "$version" "$architectures" > "$stage_dir/BUILD-INFO.txt"

archive_name="LAN-APK-Sync-$version-macos.zip"
archive_path="$project_dir/dist/$archive_name"
if [[ -e "$archive_path" ]]; then
  printf 'Archive already exists: %s\nMove it aside before creating another package.\n' "$archive_path" >&2
  exit 1
fi
ditto -c -k --norsrc --noextattr --noqtn --keepParent "$stage_dir" "$archive_path"
unzip -tq "$archive_path"
cd "$project_dir/dist"
shasum -a 256 "$archive_name" > "$archive_name.sha256"
shasum -a 256 -c "$archive_name.sha256"
printf '\nPackage: %s\nArchitectures: %s\n' "$archive_path" "$architectures"
