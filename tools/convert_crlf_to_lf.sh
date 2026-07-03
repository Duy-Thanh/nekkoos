#!/usr/bin/env bash
set -euo pipefail

echo "Starting CRLF→LF conversion (text files only). Backups: .bak"
changed=0
while IFS= read -r -d '' f; do
  if file "$f" | grep -qi 'text'; then
    if grep -q $'\r' "$f"; then
      cp -- "$f" "$f.bak"
      awk '{ sub(/\r$/,"" ); print }' "$f" > "$f.tmp"
      mv "$f.tmp" "$f"
      echo "Converted: $f"
      changed=$((changed+1))
    fi
  fi
done < <(find . -type f -print0)

echo "Done. Converted $changed files. Backups saved with .bak extension."
