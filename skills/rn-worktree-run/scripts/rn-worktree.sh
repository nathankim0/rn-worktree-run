#!/usr/bin/env bash
# Fast React Native dev builds inside git worktrees (macOS).
#
#   setup               Clone dependencies from the main worktree (APFS copy-on-write) and install
#   run <ios|android>   Install a cached native build with the same fingerprint, or build with ccache and cache it
#   build <ios|android> Ignore the cache, build, and cache the result
#   fingerprint <ios|android>
#   metro-status        free | here <pid> | other <pid> <dir>
#
# Environment overrides (all optional):
#   RNWT_POST_SETUP      Shell command run after install in `setup` (e.g. codegen / compile steps)
#   RNWT_COPY_FILES      Untracked files to copy from the main worktree (default: .env ios/.xcode.env.local android/local.properties)
#   RNWT_EXTRA_PATHS     Extra repo paths that affect the native build (e.g. "packages")
#   RNWT_IOS_CMD         Default: "<pm> run ios --no-packager"
#   RNWT_ANDROID_CMD     Default: "<pm> run android --no-packager"
#   RNWT_METRO_PORT      Default: 8081
#   RNWT_CACHE_DIR       Default: ~/Library/Caches/rn-worktree-run/<repo-name>
set -euo pipefail

HERE=$(git rev-parse --show-toplevel)
MAIN=$(git -C "$HERE" worktree list --porcelain | sed -n '1s/^worktree //p')
REPO_NAME=$(basename "$MAIN")
CACHE_DIR=${RNWT_CACHE_DIR:-$HOME/Library/Caches/rn-worktree-run/$REPO_NAME}
METRO_PORT=${RNWT_METRO_PORT:-8081}
COPY_FILES=${RNWT_COPY_FILES:-.env ios/.xcode.env.local android/local.properties}

if [ -f "$HERE/yarn.lock" ]; then PM=yarn
elif [ -f "$HERE/pnpm-lock.yaml" ]; then PM=pnpm
elif [ -f "$HERE/bun.lock" ] || [ -f "$HERE/bun.lockb" ]; then PM=bun
else PM=npm; fi

# Share C/C++/ObjC compile results across worktrees whose absolute paths differ.
if command -v ccache >/dev/null 2>&1; then
  export CCACHE_BASEDIR=$HOME CCACHE_NOHASHDIR=1 CCACHE_MAXSIZE=${CCACHE_MAXSIZE:-20G}
  export USE_CCACHE=1 CMAKE_C_COMPILER_LAUNCHER=ccache CMAKE_CXX_COMPILER_LAUNCHER=ccache
fi

log() { printf '\033[1;34m[rn-worktree]\033[0m %s\n' "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

clone() {
  local src=$1 dst=$2
  [ -e "$dst" ] || [ ! -e "$src" ] && return 0
  log "clone ${src#"$MAIN"/} (APFS copy-on-write)"
  mkdir -p "$(dirname "$dst")"
  cp -cR "$src" "$dst"
}

native_paths() {
  NATIVE_PATHS=(package.json yarn.lock pnpm-lock.yaml package-lock.json bun.lock bun.lockb
    patches .yarn/patches app.json app.config.js app.config.ts react-native.config.js)
  # shellcheck disable=SC2206
  if [ -n "${RNWT_EXTRA_PATHS:-}" ]; then NATIVE_PATHS+=(${RNWT_EXTRA_PATHS}); fi
  case $1 in
    ios) NATIVE_PATHS+=(ios ':(exclude)ios/Podfile.lock' Gemfile Gemfile.lock) ;;
    android) NATIVE_PATHS+=(android) ;;
    *) die "platform must be ios or android" ;;
  esac
}

# Hash of tracked native inputs + uncommitted changes + .env (Podfile.lock excluded: its checksums vary per machine).
fingerprint() {
  local dir=$1 platform=$2
  native_paths "$platform"
  {
    echo "$platform"
    git -C "$dir" ls-files -s -- "${NATIVE_PATHS[@]}" 2>/dev/null
    git -C "$dir" diff HEAD --binary -- "${NATIVE_PATHS[@]}" 2>/dev/null
    (cd "$dir" && git ls-files -o --exclude-standard -z -- "${NATIVE_PATHS[@]}" 2>/dev/null | xargs -0 shasum 2>/dev/null || true)
    if [ -f "$dir/.env" ]; then shasum <"$dir/.env"; fi
  } | shasum | cut -c1-16
}

newest_native_mtime() {
  local dir=$1 platform=$2
  native_paths "$platform"
  (cd "$dir" && git ls-files -z -- "${NATIVE_PATHS[@]}" 2>/dev/null | xargs -0 stat -f %m 2>/dev/null | sort -n | tail -1)
  if [ -f "$dir/.env" ]; then stat -f %m "$dir/.env"; fi
}

built_artifact() {
  local dir=$1 platform=$2 d wp app
  if [ "$platform" = android ]; then
    ls -t "$dir"/android/app/build/outputs/apk/*/*debug*.apk "$dir"/android/app/build/outputs/apk/*/*/*debug*.apk 2>/dev/null | head -1 || true
    return 0
  fi
  for d in "$HOME"/Library/Developer/Xcode/DerivedData/*; do
    wp=$(plutil -extract WorkspacePath raw "$d/info.plist" 2>/dev/null) || continue
    [ "$(dirname "$wp")" -ef "$dir/ios" ] || continue
    app=$(ls -dt "$d"/Build/Products/*-iphonesimulator/*.app 2>/dev/null | head -1)
    [ -n "$app" ] && { echo "$app"; return 0; }
  done
}

# Cache an artifact only if it is newer than every native input in that worktree.
save_from() {
  local dir=$1 platform=$2 art fp newest dest
  art=$(built_artifact "$dir" "$platform")
  [ -n "$art" ] || return 1
  newest=$(newest_native_mtime "$dir" "$platform" | sort -n | tail -1)
  [ "$(stat -f %m "$art")" -ge "${newest:-0}" ] || { log "$platform build in $dir is older than its native sources; not caching"; return 1; }
  fp=$(fingerprint "$dir" "$platform")
  dest="$CACHE_DIR/$platform-$fp"
  rm -rf "$dest.tmp" && mkdir -p "$dest.tmp"
  cp -cR "$art" "$dest.tmp/"
  rm -rf "$dest" && mv "$dest.tmp" "$dest"
  log "cached: $dest"
  ls -dt "$CACHE_DIR/$platform"-* 2>/dev/null | tail -n +7 | while read -r old; do rm -rf "$old"; done
}

cached_artifact() {
  local platform=$1 fp hit
  fp=$(fingerprint "$HERE" "$platform")
  hit=$(ls -d "$CACHE_DIR/$platform-$fp"/*.app "$CACHE_DIR/$platform-$fp"/*.apk 2>/dev/null | head -1)
  if [ -z "$hit" ] && [ "$HERE" != "$MAIN" ] && [ "$(fingerprint "$MAIN" "$platform")" = "$fp" ]; then
    save_from "$MAIN" "$platform" || true
    hit=$(ls -d "$CACHE_DIR/$platform-$fp"/*.app "$CACHE_DIR/$platform-$fp"/*.apk 2>/dev/null | head -1)
  fi
  [ -n "$hit" ] && echo "$hit"
}

ensure_simulator() {
  if ! xcrun simctl list devices booted | grep -q Booted; then
    local udid
    udid=$(xcrun simctl list devices available | grep -m1 'iPhone' | grep -oE '[0-9A-F-]{36}') || die "no available iPhone simulator"
    log "booting simulator $udid"
    xcrun simctl boot "$udid"
  fi
  open "$(xcode-select -p)/Applications/Simulator.app" 2>/dev/null || open -a Simulator 2>/dev/null || true
}

sdk_dir() { echo "${ANDROID_HOME:-${ANDROID_SDK_ROOT:-$HOME/Library/Android/sdk}}"; }

ensure_android_device() {
  adb start-server >/dev/null
  if ! adb devices | sed 1d | grep -q 'device$'; then
    local emulator avd
    emulator="$(sdk_dir)/emulator/emulator"
    avd=$("$emulator" -list-avds | head -1)
    [ -n "$avd" ] || die "no connected device and no AVD"
    log "starting emulator $avd"
    nohup "$emulator" -avd "$avd" >/dev/null 2>&1 &
    adb wait-for-device
  fi
  until [ "$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = 1 ]; do sleep 2; done
}

apk_package() {
  local aapt2
  aapt2=$(ls -d "$(sdk_dir)"/build-tools/*/aapt2 2>/dev/null | sort | tail -1)
  [ -n "$aapt2" ] || die "aapt2 not found in Android build-tools"
  "$aapt2" dump packagename "$1"
}

install_and_launch() {
  local platform=$1 art=$2 id
  if [ "$platform" = ios ]; then
    ensure_simulator
    id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$art/Info.plist")
    xcrun simctl install booted "$art"
    xcrun simctl launch booted "$id"
  else
    ensure_android_device
    id=$(apk_package "$art")
    adb install -r "$art"
    adb reverse tcp:"$METRO_PORT" tcp:"$METRO_PORT"
    adb shell monkey -p "$id" -c android.intent.category.LAUNCHER 1 >/dev/null
  fi
}

ensure_pods() {
  [ "$HERE" = "$MAIN" ] || clone "$MAIN/ios/Pods" "$HERE/ios/Pods"
  local stamp
  stamp="$HERE|${USE_CCACHE:-0}|$(cat "$HERE/ios/Podfile" "$HERE/ios/Podfile.lock" "$HERE/package.json" 2>/dev/null | shasum)"
  [ "$(cat "$HERE/ios/Pods/.rnwt-pod-stamp" 2>/dev/null)" = "$stamp" ] && return 0
  log "pod install (USE_CCACHE=${USE_CCACHE:-0})"
  if [ -f "$HERE/Gemfile" ] && grep -q cocoapods "$HERE/Gemfile"; then
    (cd "$HERE/ios" && bundle exec pod install)
  else
    (cd "$HERE/ios" && pod install)
  fi
  echo "$stamp" >"$HERE/ios/Pods/.rnwt-pod-stamp"
}

native_build() {
  local platform=$1
  cd "$HERE"
  if [ "$platform" = ios ]; then
    ensure_pods
    eval "${RNWT_IOS_CMD:-$PM run ios --no-packager}"
  else
    eval "${RNWT_ANDROID_CMD:-$PM run android --no-packager}"
  fi
  save_from "$HERE" "$platform" || log "build artifact not found; not cached"
}

cmd_setup() {
  cd "$HERE"
  local f
  for f in $COPY_FILES; do
    [ -e "$HERE/$f" ] || [ ! -e "$MAIN/$f" ] || { mkdir -p "$(dirname "$HERE/$f")"; cp "$MAIN/$f" "$HERE/$f"; log "copy $f"; }
  done
  if [ "$HERE" != "$MAIN" ]; then
    clone "$MAIN/.yarn/cache" "$HERE/.yarn/cache"
    clone "$MAIN/.yarn/install-state.gz" "$HERE/.yarn/install-state.gz"
    if [ ! -e "$HERE/node_modules" ] && [ -e "$MAIN/node_modules" ]; then
      clone "$MAIN/node_modules" "$HERE/node_modules"
      # Native build outputs inside node_modules embed the main worktree path; drop them.
      find "$HERE/node_modules" -type d \( -path '*/android/build' -o -path '*/android/.cxx' -o -path '*/node_modules/.cache' \) -prune -exec rm -rf {} + 2>/dev/null || true
    fi
  fi
  $PM install
  if [ -n "${RNWT_POST_SETUP:-}" ]; then
    log "post-setup: $RNWT_POST_SETUP"
    eval "$RNWT_POST_SETUP"
  fi
}

cmd_metro_status() {
  local pid dir
  pid=$(lsof -nP -iTCP:"$METRO_PORT" -sTCP:LISTEN -t 2>/dev/null | head -1)
  [ -n "$pid" ] || { echo free; return; }
  dir=$(lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p')
  if [ "$dir" -ef "$HERE" ]; then echo "here $pid"; else echo "other $pid $dir"; fi
}

case ${1:-} in
  setup) cmd_setup ;;
  run)
    platform=${2:?platform}
    native_paths "$platform"
    if art=$(cached_artifact "$platform"); then
      log "cache hit: $art (skipping native build)"
      install_and_launch "$platform" "$art"
    else
      log "cache miss: building native app"
      native_build "$platform"
    fi
    ;;
  build) native_paths "${2:?platform}" && native_build "$2" ;;
  fingerprint) fingerprint "$HERE" "${2:?platform}" ;;
  metro-status) cmd_metro_status ;;
  *) sed -n '2,18p' "$0"; exit 1 ;;
esac
