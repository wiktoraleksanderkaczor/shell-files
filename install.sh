#!/bin/zsh
REPO="$(cd "$(dirname "$0")" && pwd)"

for f in .zshrc .p10k.zsh; do
  rm -f "$HOME/$f"
  ln -s "$REPO/$f" "$HOME/$f"
  echo "linked $HOME/$f → $REPO/$f"
done
