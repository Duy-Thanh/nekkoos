#!/usr/bin/env python3
"""
Platform authenticity gate test (hardware_checks.pas).

Boots with the fw_cfg key REMOVED. The kernel must stop at the key prompt
rather than reach the login screen; typing the correct key must then let
boot continue to "Username:". This exercises the path smoke_test.py never
takes, because its QEMU command line always supplies the key.
"""
import os
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import smoke_test as st  # noqa: E402

KEY = "DUY_THANH_IS_THE_KING"


def key_commands(text):
    cmds = []
    for ch in text:
        if ch == "_":
            cmds.append("sendkey shift-minus")
        elif ch.isupper():
            cmds.append(f"sendkey shift-{ch.lower()}")
        else:
            cmds.append(f"sendkey {st.KEYMAP.get(ch, ch)}")
    return cmds


def main():
    st.require(st.OVMF, "OVMF firmware")
    st.require(st.HDD, "disk image (hdd.img)")
    st.cleanup()
    args = [a for a in st.QEMU_ARGS]
    i = args.index("-fw_cfg")
    del args[i:i + 2]                       # drop the key

    res = st.Result()
    qemu = None
    try:
        with open(st.SERIAL_LOG, "wb"):
            pass
        qemu = subprocess.Popen(args, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

        # Give the kernel time to get to the gate; it must NOT reach the login
        # prompt on its own.
        time.sleep(25)
        reached = "Username:" in st.read_serial_log()
        res.record("without the key, boot stops before login", not reached)

        st.mon_send(key_commands(KEY) + ["sendkey ret"], 0.08)
        ok = st.wait_for(r"Username:", timeout=150, window=300)
        res.record("typing the key lets boot continue to login", ok)
    finally:
        try:
            time.sleep(1.0)
            st.archive_serial_log("hwcheck")
        except Exception:
            pass
        if qemu and qemu.poll() is None:
            qemu.terminate()
            try:
                qemu.wait(timeout=5)
            except subprocess.TimeoutExpired:
                qemu.kill()
        st.cleanup()

    print(f"  {res.passed}/{res.passed + res.failed} passed")
    sys.exit(0 if res.failed == 0 else 1)


if __name__ == "__main__":
    main()
