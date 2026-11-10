#!/bin/sh
# Wrapped in a function so the whole script is read before it runs.
# The rebase temporarily removes this file from disk.
set -e
main() {
  branch=$(git rev-parse --abbrev-ref HEAD)
  if [ "$branch" = "main" ]; then
    echo "Run this from your feature branch, not main."
    exit 1
  fi
  git fetch upstream main:main
  git push origin main
  git rebase --autostash main
  git push --force-with-lease origin "$branch"
}
main "$@"; exit