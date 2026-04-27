#!/usr/bin/env zsh
# Symlinks kiro/ files into ~/.kiro, preserving directory structure.

REPO_DIR="${0:A:h}"
KIRO_SRC="$REPO_DIR/kiro"
KIRO_DST="$HOME/.kiro"

files=(
  agents/instruct.json
  agents/main.json
  agents/ralph.json
  prompts/audit.md
  prompts/learn.md
  prompts/plan.md
  prompts/handoff.md
  steering/WORKFLOW-UPDATE-GUIDE.md
  steering/WORKFLOW.md
)

for f in $files; do
  src="$KIRO_SRC/$f"
  dst="$KIRO_DST/$f"
  mkdir -p "${dst:h}"
  if [[ -L "$dst" ]]; then
    echo "already linked: $f"
  elif [[ -e "$dst" ]]; then
    echo "backing up existing: $f"
    mv "$dst" "${dst}.bak"
    ln -s "$src" "$dst"
    echo "linked: $f"
  else
    ln -s "$src" "$dst"
    echo "linked: $f"
  fi
done
