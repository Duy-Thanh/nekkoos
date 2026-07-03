#!/usr/bin/env bash
LOGDIR=/tmp/nekko_fuzz_logs
if [ ! -d "$LOGDIR" ]; then echo "No logs dir"; exit 1; fi
grep -h "RIP:" $LOGDIR/*.log | sed -E 's/.*RIP: *0x([0-9A-Fa-f]+).*/\1/' | sort | uniq -c | sort -nr
