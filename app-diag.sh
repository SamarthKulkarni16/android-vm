#!/bin/bash
# CEO 2026-10-27: ONE-SHOT, read-only Snapchat diagnostics (round 2). Watches Snapchat for ~3.5 minutes so that a login attempt
# made by hand during that window is captured. The repo is PUBLIC: only warnings/errors of the Snapchat process, redacted.
OUT=logs/app-diag.txt
REQ=logs/app-diag-request.txt
[ -f "$REQ" ] || exit 0
ID=$(grep -m1 '^id:' "$REQ" | sed 's/^id: *//')
if [ -f "$OUT" ] && head -1 "$OUT" | grep -q "^id: $ID\$"; then echo "app-diag $ID already done"; exit 0; fi

red() { sed -E 's/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/[EMAIL]/g; s/[0-9]{1,3}(\.[0-9]{1,3}){3}/x.x.x.x/g; s/[A-Za-z0-9+\/_=-]{28,}/[LONG]/g' | iconv -c -f utf-8 -t ascii//TRANSLIT | cut -c1-240; }
A() { timeout 25 adb shell "$@" 2>&1; }
P=com.snapchat.android

sleep 90   # let the phone settle (Play Store auto-updates hog the CPU right after boot)

{
echo "id: $ID"
echo "run: ${RUN_ID:-?}   utc: $(date -u +%FT%TZ)"
echo "=== hardware the phone actually got ==="
A cat /proc/meminfo | grep -E 'MemTotal|MemAvailable|SwapTotal|SwapFree'
A nproc
for k in dalvik.vm.heapsize dalvik.vm.heapgrowthlimit dalvik.vm.heapstartsize; do echo "$k = $(A getprop $k)"; done
grep -E 'hw.ramSize|vm.heapSize|hw.cpu.ncore|hw.camera' "$HOME/.android/avd/persistent_avd.avd/config.ini" | sort | uniq -c
A dumpsys media.camera | grep -E 'Number of camera devices|Facing' | head -4
echo "=== top CPU users right now ==="; A top -b -n 1 | head -10
A am force-stop $P
adb logcat -c >/dev/null 2>&1
echo "=== launching Snapchat $(date -u +%T): log in by hand now if you want the hang captured ==="
A monkey -p $P -c android.intent.category.LAUNCHER 1 | tail -1
for i in 1 2 3 4 5 6 7; do
  sleep 30
  PID=$(A pidof $P)
  echo "--- t+$((i*30))s pid=[$PID] $(A grep -E 'MemAvailable|SwapFree' /proc/meminfo | tr -s ' ' | tr '\n' ' ')"
  A dumpsys window | grep -E 'mCurrentFocus' | head -1
done
PID=$(A pidof $P)
echo "=== Snapchat process warnings/errors (pid $PID) ==="
[ -n "$PID" ] && timeout 40 adb logcat -d --pid=$PID -v threadtime '*:W' 2>&1 | tail -150
echo "=== kills / low memory / ANR involving Snapchat ==="
timeout 40 adb logcat -d -b events,system -v threadtime 2>&1 | grep -iE 'snapchat' | grep -iE 'am_kill|am_proc_died|am_low_memory|lmkd|lowmemory|Killing|ANR|am_crash|am_anr|Force finishing|died' | tail -30
echo "=== crash buffer ==="; timeout 25 adb logcat -d -b crash -v threadtime 2>&1 | tail -30
A input keyevent KEYCODE_HOME
echo "=== diag finished $(date -u +%T) ==="
} 2>&1 | red | head -c 60000 > "$OUT"
echo "app-diag $ID written to $OUT ($(wc -c < "$OUT") bytes)"
