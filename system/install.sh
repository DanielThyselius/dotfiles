#!/usr/bin/env bash
# Install system-level config that lives outside $HOME (stow can't manage it).
# Mirrors this directory's etc/ tree into /etc. Idempotent; run after `git pull`
# whenever something under system/etc/ changes.
set -euo pipefail
cd "$(dirname "$0")"

find etc -type f | while read -r f; do
  if ! sudo diff -q "$f" "/$f" >/dev/null 2>&1; then
    sudo install -Dm644 "$f" "/$f"
    echo "installed /$f"
  fi
done

echo
echo "Done. logind config takes effect on next boot."
echo "Do NOT 'systemctl restart systemd-logind' from a live session:"
echo "it revokes Hyprland's seat and kills the whole graphical session."
