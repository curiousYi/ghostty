#!/bin/sh
set -e
cd "$(git rev-parse --show-toplevel)"

git remote get-url upstream >/dev/null 2>&1 || \
  git remote add upstream git@github.com:ghostty-org/ghostty.git

for hook in .fork/hooks/*; do
  ln -sf "../../$hook" ".git/hooks/$(basename "$hook")"
done
git config rerere.enabled true
echo "Fork setup done."