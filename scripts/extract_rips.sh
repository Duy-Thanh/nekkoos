#!/usr/bin/env bash
for f in /tmp/nekko_fuzz_logs/*.log; do
  rip=$(awk '/GENERAL PROTECTION FAULT/{found=1} found && /RIP:/{if(match($0,/0x[0-9A-Fa-f]+/)) print gensub(/.*(0x[0-9A-Fa-f]+).*/,"\\1","g",$0); else {getline; if(match($0,/0x[0-9A-Fa-f]+/)) print gensub(/.*(0x[0-9A-Fa-f]+).*/,"\\1","g",$0);} exit}' "$f")
  echo "$(basename $f): ${rip:-<no-rip-found>}"
done
