#!/usr/bin/env bash
# Link the skill into ~/.claude/skills so `git pull` in this repo updates it.
set -euo pipefail
src="$(cd "$(dirname "$0")" && pwd)/skills/rn-worktree-run"
dst="$HOME/.claude/skills/rn-worktree-run"
mkdir -p "$HOME/.claude/skills"
if [ -e "$dst" ] && [ ! -L "$dst" ]; then
  echo "$dst exists and is not a symlink; remove it first." >&2
  exit 1
fi
ln -sfn "$src" "$dst"
echo "Linked $dst -> $src"
command -v ccache >/dev/null || echo "Tip: brew install ccache  (shares native compile results across worktrees)"
