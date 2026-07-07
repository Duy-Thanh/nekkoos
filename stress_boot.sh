#!/usr/bin/env bash
# ============================================================
# NekkoOS ACPI Stress Test - 20 lần boot tự động (NixOS)
# Dùng nix-shell shell.nix để có đủ PATH: nasm, bflat, qemu...
# ============================================================

NEKKOOS_DIR="$(cd "$(dirname "$0")" && pwd)"

# Nếu chưa đang chạy trong nix-shell, re-exec qua nix-shell
if [ -z "${IN_NIX_SHELL:-}" ]; then
    exec nix-shell "$NEKKOOS_DIR/shell.nix" --run "bash '$0' $*"
fi

set -euo pipefail
cd "$NEKKOOS_DIR"

RUNS=20
TIMEOUT=60          # Giây tối đa chờ boot (thấy "ACPI Daemon Armed")
ACPI_TIMEOUT=20     # Giây tối đa chờ QEMU tự tắt sau boot

PASS=0
FAIL=0
RESULTS=()

# QEMU headless, -no-reboot để QEMU thoát ngay khi nhận ACPI S5
QEMU_CMD="qemu-system-x86_64
  -accel kvm
  -machine q35,smm=on
  -global ICH9-LPC.disable_s3=1
  -global ICH9-LPC.disable_s4=1
  -smp 2
  -device piix3-ide,id=ide
  -drive file=hdd.img,format=raw,if=none,id=drv0
  -device ide-hd,bus=ide.0,drive=drv0
  -bios OVMF_X64.fd
  -net nic -net user
  -m 4G
  -fw_cfg name=opt/nekko_key,string=DUY_THANH_IS_THE_KING
  -nographic
  -no-reboot"

echo "============================================================"
echo "  NekkoOS ACPI Stress Boot Test - $RUNS lần  [nix-shell OK]"
echo "============================================================"
echo ""

# ---- Build một lần duy nhất ----
echo "[BUILD] Đang build NekkoOS qua build.sh..."
if bash build.sh > /tmp/nekko_build.log 2>&1; then
    echo "[BUILD] ✓ Build thành công!"
else
    echo "[BUILD] ✗ BUILD THẤT BẠI! Log:"
    cat /tmp/nekko_build.log
    exit 1
fi
echo ""

# ---- Stress test vòng lặp ----
for i in $(seq 1 $RUNS); do
    LOG="/tmp/nekko_boot_${i}.log"
    rm -f "$LOG"
    printf "[BOOT %2d/%d] Đang khởi động..." "$i" "$RUNS"

    # Chạy QEMU ngầm, redirect serial -> file log
    $QEMU_CMD -serial "file:$LOG" > /dev/null 2>&1 &
    QEMU_PID=$!

    # --- Giai đoạn 1: Đợi kernel boot xong (thấy "ACPI Daemon Armed") ---
    BOOTED=0
    for t in $(seq 1 $TIMEOUT); do
        sleep 1
        if [ -f "$LOG" ] && grep -q "ACPI Daemon Armed" "$LOG" 2>/dev/null; then
            BOOTED=1
            break
        fi
        if ! kill -0 "$QEMU_PID" 2>/dev/null; then
            # QEMU đã thoát sớm (có thể crash)
            break
        fi
    done

    if [ $BOOTED -eq 0 ]; then
        kill "$QEMU_PID" 2>/dev/null || true
        wait "$QEMU_PID" 2>/dev/null || true
        printf " ✗ FAIL (Boot timeout >%ds)\n" "$TIMEOUT"
        RESULTS+=("BOOT $i: FAIL — Boot timeout (không thấy 'ACPI Daemon Armed' trong ${TIMEOUT}s)")
        FAIL=$((FAIL + 1))
        continue
    fi

    # --- Giai đoạn 2: Chờ QEMU tự tắt (ACPI shutdown) ---
    SHUTDOWN_OK=0
    for t in $(seq 1 $ACPI_TIMEOUT); do
        sleep 1
        if ! kill -0 "$QEMU_PID" 2>/dev/null; then
            SHUTDOWN_OK=1
            break
        fi
    done

    if [ $SHUTDOWN_OK -eq 1 ]; then
        # Kiểm tra log có lỗi nghiêm trọng không
        if grep -qE "ACPI DAEMON FAILED|Triple Fault|KERNEL PANIC|#GP|#PF|#UD|#DF" "$LOG" 2>/dev/null; then
            printf " ✗ FAIL (Crash/Panic)\n"
            RESULTS+=("BOOT $i: FAIL — Crash/Panic trong serial log")
            FAIL=$((FAIL + 1))
        else
            printf " ✓ PASS\n"
            RESULTS+=("BOOT $i: PASS")
            PASS=$((PASS + 1))
        fi
    else
        # QEMU vẫn sống sau ACPI_TIMEOUT => ACPI không tắt được hardware
        kill "$QEMU_PID" 2>/dev/null || true
        wait "$QEMU_PID" 2>/dev/null || true
        DETAIL=""
        if grep -q "ACPI DAEMON FAILED" "$LOG" 2>/dev/null; then
            DETAIL="ACPI daemon báo FAILED"
        elif grep -q "Delegating Hardware Power-off" "$LOG" 2>/dev/null; then
            DETAIL="IPC gửi OK nhưng daemon không tắt được hardware"
        else
            DETAIL="QEMU vẫn chạy sau ${ACPI_TIMEOUT}s, không rõ nguyên nhân"
        fi
        printf " ✗ FAIL (ACPI timeout — %s)\n" "$DETAIL"
        RESULTS+=("BOOT $i: FAIL — ACPI shutdown timeout: $DETAIL")
        FAIL=$((FAIL + 1))
    fi
    wait "$QEMU_PID" 2>/dev/null || true
done

# ---- Tổng kết ----
echo ""
echo "============================================================"
echo "  KẾT QUẢ STRESS TEST"
echo "============================================================"
for r in "${RESULTS[@]}"; do
    echo "  $r"
done
echo ""
echo "  ✓ PASS: $PASS / $RUNS"
echo "  ✗ FAIL: $FAIL / $RUNS"

if [ $FAIL -eq 0 ]; then
    echo ""
    echo "  🎉 TẤT CẢ $RUNS LẦN BOOT + ACPI SHUTDOWN THÀNH CÔNG!"
else
    echo ""
    echo "  ⚠️  $FAIL LẦN THẤT BẠI. Tail serial log của các lần FAIL:"
    for i in $(seq 1 $RUNS); do
        r="${RESULTS[$((i-1))]}"
        if [[ "$r" == *"FAIL"* ]]; then
            echo ""
            echo "  --- Boot $i (/tmp/nekko_boot_${i}.log) ---"
            tail -40 "/tmp/nekko_boot_${i}.log" 2>/dev/null || echo "    (không có log)"
        fi
    done
fi
echo "============================================================"
