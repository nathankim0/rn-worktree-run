---
name: rn-worktree-run
description: Build and run a React Native app (iOS simulator / Android emulator dev build) quickly, especially inside a git worktree on macOS. Use when the user asks to build, run, launch, or "실행/빌드" the app in a React Native repo. Reuses the main worktree's node_modules and Pods via APFS clones, skips native compilation entirely when a build with the same native fingerprint is cached, and shares C/C++ compile results across worktrees with ccache. Not for JS-only compile steps or release builds.
---

# Fast React Native build & run in worktrees

Use only when the user explicitly asks to build or run the app. Run every command from the root of the worktree you are working in.

```bash
S=~/.claude/skills/rn-worktree-run/scripts/rn-worktree.sh
```

If the skill was installed as a plugin, use the plugin's copy of `scripts/rn-worktree.sh` next to this file instead.

## How it is fast

- `setup` clones `node_modules`, `.yarn/cache`, and untracked config files (`.env`, `ios/.xcode.env.local`, `android/local.properties`) from the main worktree (first entry of `git worktree list`) with `cp -c` (APFS copy-on-write), then runs the package manager's install, which is near-instant when the lockfile matches.
- `run <ios|android>` fingerprints the files that affect the native binary (`ios/` or `android/`, `package.json`, lockfiles, patches, app config, `.env`; `ios/Podfile.lock` excluded because its checksums differ between machines). A cached `.app`/`.apk` with the same fingerprint is installed and launched without compiling. Debug builds load JS from Metro, so JS-only branches start in seconds. If the cache is empty but the main worktree has a fresh build with the same fingerprint, that build seeds the cache.
- On a cache miss it clones `ios/Pods`, runs `pod install` with `USE_CCACHE=1`, and builds with `CCACHE_BASEDIR=$HOME` + `CCACHE_NOHASHDIR=1` (Android: `CMAKE_*_COMPILER_LAUNCHER=ccache`, plus Gradle's own build cache), then caches the artifact for the next worktree.

## Steps

1. Read the project's agent instructions (`CLAUDE.md`, `AGENTS.md`) and `package.json` for required codegen/compile steps after install (e.g. GraphQL codegen, compile-to-JS languages, CSS builds) and pass them in order:
   ```bash
   RNWT_POST_SETUP="yarn codegen && yarn build:js" $S setup
   ```
   Skip `setup` when the worktree is already installed and the lockfile has not changed; just run the compile steps.
2. Metro: `$S metro-status`
   - `here <pid>`: reuse it.
   - `other <pid> <dir>`: Metro from another worktree. Cached apps use the default port, so stop it with `kill <pid>` and tell the user which directory's Metro was stopped.
   - `free`: start Metro in a new Terminal window so it keeps running:
     ```bash
     osascript -e "tell application \"Terminal\" to do script \"cd '$(git rev-parse --show-toplevel)' && yarn start\""
     ```
     Use the project's own start script.
3. App: `$S run ios` and/or `$S run android`. Native builds can take minutes, so run them in the background and wait for completion.
   - Report whether the log said `cache hit` or `cache miss`.
   - After changing native code, or if a cached build looks wrong, force a rebuild with `$S build <ios|android>`.

## Configuration

Set these environment variables when the defaults do not fit:

| Variable | Default |
| --- | --- |
| `RNWT_POST_SETUP` | none |
| `RNWT_COPY_FILES` | `.env ios/.xcode.env.local android/local.properties` |
| `RNWT_EXTRA_PATHS` | none (add local native packages, e.g. `packages`) |
| `RNWT_IOS_CMD` | `<pm> run ios --no-packager` |
| `RNWT_ANDROID_CMD` | `<pm> run android --no-packager` |
| `RNWT_METRO_PORT` | `8081` |
| `RNWT_CACHE_DIR` | `~/Library/Caches/rn-worktree-run/<repo>` |

## Notes

- iOS boots the first available iPhone simulator if none is booted; Android starts the first AVD if no device is connected. Start a specific emulator yourself first when the task needs one.
- Native inputs outside the fingerprint (ignored files, Xcode/NDK upgrades) require `build`.
- The first worktree build still fills ccache. Report actual timings and `ccache -s` hits as facts, not assumptions.
- On failure, report the real error. If Pods fail right after cloning, `rm -rf ios/Pods` and run `$S run ios` once more.
