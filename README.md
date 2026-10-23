# rn-worktree-run

A [Claude Code](https://claude.com/claude-code) skill that makes React Native dev builds fast inside **git worktrees** on macOS.

A fresh worktree usually means a fresh `yarn install`, a fresh `pod install`, and a full native compile in a new DerivedData / `.cxx` directory. That makes every new worktree take many minutes before the app shows up. This skill removes most of that work:

| Step | Without | With rn-worktree-run |
| --- | --- | --- |
| `node_modules`, `.yarn/cache`, `ios/Pods` | download + link again | APFS copy-on-write clone from the main worktree (no extra disk space), then a near no-op install |
| Native build when only JS/TS changed | full Xcode / Gradle build | **skipped**: the cached `.app` / `.apk` with the same native fingerprint is installed and launched |
| Native build when native code changed | compile everything from scratch | `ccache` shared across worktrees (`CCACHE_BASEDIR`), plus Gradle's build cache |

Debug builds load JavaScript from Metro, so one native binary serves every worktree whose native inputs are identical.

## Install

### As a plugin

```
/plugin marketplace add nathankim0/rn-worktree-run
/plugin install rn-worktree-run@rn-worktree-run
```

### As a personal skill (symlink, updates with `git pull`)

```bash
git clone https://github.com/nathankim0/rn-worktree-run ~/rn-worktree-run
~/rn-worktree-run/install.sh
brew install ccache   # recommended
```

Then ask Claude Code to "run the app on iOS" (or Android) in any worktree of a React Native repo.

## Usage without Claude

```bash
S=~/.claude/skills/rn-worktree-run/scripts/rn-worktree.sh

RNWT_POST_SETUP="yarn codegen" $S setup   # clone deps from main worktree, install, run your codegen
$S metro-status                            # free | here <pid> | other <pid> <dir>
yarn start                                 # in another terminal
$S run ios                                 # cache hit: install + launch; miss: build with ccache, then cache
$S run android
$S build ios                               # force a native rebuild
```

## How the native fingerprint works

The fingerprint is a hash of:

- tracked files under `ios/` (except `Podfile.lock`) or `android/`
- `package.json`, lockfiles, `patches/`, `.yarn/patches/`, `app.json`, `app.config.*`, `react-native.config.js`, `Gemfile*`
- paths listed in `RNWT_EXTRA_PATHS`
- uncommitted changes and untracked files in those paths
- `.env` (often baked into native builds by `react-native-config`)

Artifacts are cached only when they are newer than every native input of the worktree that built them. The cache keeps the 6 most recent builds per platform in `~/Library/Caches/rn-worktree-run/<repo>`.

## Configuration

| Variable | Default |
| --- | --- |
| `RNWT_POST_SETUP` | none, a command run after install (codegen, compile steps) |
| `RNWT_COPY_FILES` | `.env ios/.xcode.env.local android/local.properties` |
| `RNWT_EXTRA_PATHS` | none, e.g. `packages` for local native modules |
| `RNWT_IOS_CMD` | `<pm> run ios --no-packager` |
| `RNWT_ANDROID_CMD` | `<pm> run android --no-packager` |
| `RNWT_METRO_PORT` | `8081` |
| `RNWT_CACHE_DIR` | `~/Library/Caches/rn-worktree-run/<repo>` |

## Requirements and limits

- macOS with an APFS volume (for `cp -c`), Xcode and/or the Android SDK.
- The `ios` / `android` npm scripts must build a debug variant (the defaults of the React Native CLI do).
- Changes outside the fingerprint (ignored files, Xcode/NDK upgrades) need `build` to force a rebuild.
- Cached iOS apps are simulator builds; physical devices are not handled.

## License

MIT
