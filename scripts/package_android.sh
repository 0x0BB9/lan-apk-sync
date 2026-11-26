#!/bin/bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
project_dir="$(cd -- "$script_dir/.." && pwd)"
sdk_dir="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
build_tools_version="${ANDROID_BUILD_TOOLS_VERSION:-36.0.0}"
signer="$sdk_dir/build-tools/$build_tools_version/apksigner"
if [[ ! -x "$signer" ]]; then
  printf '%s\n' 'Set ANDROID_HOME to an Android SDK with build-tools 36.0.0, or set ANDROID_BUILD_TOOLS_VERSION.' >&2
  exit 1
fi

cd "$project_dir/android-receiver"
./gradlew testDebugUnitTest lintDebug lintRelease assembleDebug assembleRelease \
  --offline --no-daemon --max-workers=2

apk_path="$project_dir/android-receiver/app/build/outputs/apk/release/app-release.apk"
metadata="$project_dir/android-receiver/app/build/outputs/apk/release/output-metadata.json"
version="$(sed -nE 's/.*"versionName": "([^"]+)".*/\1/p' "$metadata" | head -n 1)"
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  printf '%s\n' 'Cannot determine APK version.' >&2
  exit 1
fi
"$signer" verify --verbose --print-certs "$apk_path"
unzip -tq "$apk_path"

mkdir -p "$project_dir/dist"
apk_name="LAN-APK-Receiver-$version.apk"
if [[ -e "$project_dir/dist/$apk_name" ]]; then
  printf 'Package already exists: %s\nMove it aside before packaging again.\n' "$project_dir/dist/$apk_name" >&2
  exit 1
fi
cp "$apk_path" "$project_dir/dist/$apk_name"
cp "$project_dir/docs/ANDROID.md" "$project_dir/dist/ANDROID-使用说明.md"
cd "$project_dir/dist"
shasum -a 256 "$apk_name" > "$apk_name.sha256"
shasum -a 256 -c "$apk_name.sha256"
printf '\nPackage: %s\nInternal test signing only; keep the signing key private for future updates.\n' \
  "$project_dir/dist/$apk_name"
