#!/usr/bin/env bash
set -euo pipefail
ITER=${ITER:-50}
OUT=/tmp/fuzz_results.txt
rm -f "$OUT"
mkdir -p /tmp/nekko_fuzz_logs

# How long to wait for a boot marker to appear in the build log (seconds)
MAX_BOOT_WAIT=40
# How long to keep the OS running after boot marker is seen (seconds)
BOOT_LIVE=10
# Grace period to allow build.sh to exit after we signal termination
KILL_GRACE=5

for i in $(seq 1 $ITER); do
  echo "===== RUN $i =====" | tee -a "$OUT"
  rm -f /tmp/build_run.log

  # Start build (which launches QEMU) in background and capture its PID
  ./build.sh > /tmp/build_run.log 2>&1 &
  BUILD_PID=$!

  # Wait up to MAX_BOOT_WAIT seconds for a boot marker in the log.
  boot_detected=0
  waited=0
  while kill -0 "$BUILD_PID" 2>/dev/null && [ $waited -lt $MAX_BOOT_WAIT ]; do
    if grep -q "\[INFO\] Kernel Text Address" /tmp/build_run.log 2>/dev/null; then
      boot_detected=1
      break
    fi
    sleep 1
    waited=$((waited+1))
  done

  if [ $boot_detected -eq 1 ]; then
    echo "[fuzz] Kernel boot marker detected after ${waited}s — letting it run ${BOOT_LIVE}s" | tee -a "$OUT"
    sleep $BOOT_LIVE

    # Now terminate QEMU and the build process
    pkill -f qemu-system-x86_64 || true
    kill "$BUILD_PID" 2>/dev/null || true

    grace=0
    while kill -0 "$BUILD_PID" 2>/dev/null && [ $grace -lt $KILL_GRACE ]; do
      sleep 1
      grace=$((grace+1))
    done
    if kill -0 "$BUILD_PID" 2>/dev/null; then
      kill -9 "$BUILD_PID" 2>/dev/null || true
    fi
    wait "$BUILD_PID" 2>/dev/null || true
  else
    # No boot marker seen. If build still running, terminate it (stalled); otherwise it finished early (crash/ok)
    if kill -0 "$BUILD_PID" 2>/dev/null; then
      echo "[fuzz] No boot marker after ${MAX_BOOT_WAIT}s — terminating QEMU/build" | tee -a "$OUT"
      pkill -f qemu-system-x86_64 || true
      kill "$BUILD_PID" 2>/dev/null || true
      grace=0
      while kill -0 "$BUILD_PID" 2>/dev/null && [ $grace -lt $KILL_GRACE ]; do
        sleep 1
        grace=$((grace+1))
      done
      if kill -0 "$BUILD_PID" 2>/dev/null; then
        kill -9 "$BUILD_PID" 2>/dev/null || true
      fi
      wait "$BUILD_PID" 2>/dev/null || true
    else
      # build exited before marker — nothing to do
      wait "$BUILD_PID" 2>/dev/null || true
    fi
  fi

  # Analyze the captured log for fatal kernel faults (DF / PF / GPF / Kernel Panic)
  TYPE="OK"
  if grep -q "DOUBLE FAULT" /tmp/build_run.log 2>/dev/null; then
    TYPE="DF"
  elif grep -q "PAGE FAULT" /tmp/build_run.log 2>/dev/null; then
    TYPE="PF"
  elif grep -q "GENERAL PROTECTION FAULT" /tmp/build_run.log 2>/dev/null; then
    TYPE="GPF"
  elif grep -qE "KERNEL PANIC|FATAL EXCEPTION" /tmp/build_run.log 2>/dev/null; then
    TYPE="KP"
  fi

  if [ "$TYPE" != "OK" ]; then
    echo "$TYPE:$i" | tee -a "$OUT"
    cp /tmp/build_run.log /tmp/nekko_fuzz_logs/build_run_${i}_${TYPE}.log
  else
    echo "OK:$i" | tee -a "$OUT"
  fi

  sleep 1
done
# Summary
echo "Fuzz finished. Results:" | tee -a "$OUT"
cat "$OUT"
echo "Logs saved in /tmp/nekko_fuzz_logs" | tee -a "$OUT"
