#!/bin/bash
# CEO 2026-10-26: ONE-SHOT, read-only diagnostics for Snapchat and TikTok inside the running phone.
# The repo is PUBLIC: everything is filtered (emails, IPs, long tokens removed), no screenshots, no UI dumps, no full logcat.
# Runs only when logs/app-diag-request.txt exists and its id is not yet in logs/app-diag.txt.
OUT=logs/app-diag.txt
REQ=logs/app-diag-request.txt
[ -f "$REQ" ] || exit 0
ID=$(grep -m1 '^id:' "$REQ" | sed 's/^id: *//')
if [ -f "$OUT" ] && head -1 "$OUT" | grep -q "^id: $ID\$"; then echo "app-diag $ID already done"; exit 0; fi

red() { sed -E 's/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/[EMAIL]/g; s/[0-9]{1,3}(\.[0-9]{1,3}){3}/x.x.x.x/g; s/[A-Za-z0-9+\/_=-]{28,}/[LONG]/g' | iconv -c -f utf-8 -t ascii//TRANSLIT | cut -c1-260; }
A() { timeout 25 adb shell "$@" 2>&1; }

sleep 75   # let the phone settle after boot

run_app() {  # $1 = package
  local P=$1 PID
  echo; echo "################ APP $P ################"
  A dumpsys package $P | grep -E 'versionName|versionCode|primaryCpuAbi|secondaryCpuAbi|nativeLibraryDir|firstInstallTime|lastUpdateTime' | head -8
  A pm list packages -f $P | head -2
  A am force-stop $P
  adb logcat -c >/dev/null 2>&1
  echo "--- launching $(date -u +%T)"
  A monkey -p $P -c android.intent.category.LAUNCHER 1 | tail -2
  sleep 20
  echo "--- after 20s: pid=$(A pidof $P) focus:"; A dumpsys window | grep -E 'mCurrentFocus|mFocusedApp' | head -2
  sleep 25
  PID=$(A pidof $P)
  echo "--- after 45s: pid=$PID focus:"; A dumpsys window | grep -E 'mCurrentFocus|mFocusedApp' | head -2
  echo "--- cpu snapshot (is the phone starved / translating?)"; A top -b -n 1 | head -12
  echo "--- app threads state (pid $PID)"; [ -n "$PID" ] && A "cat /proc/$PID/status | grep -E 'State|Threads|VmRSS'"
  echo "--- crash buffer"; timeout 25 adb logcat -d -b crash -v threadtime 2>&1 | tail -40
  echo "--- filtered main/system/events log (errors, native, translation, GL, camera, network, integrity)"
  timeout 40 adb logcat -d -b main,system,events -v threadtime 2>&1 | grep -iE "$P|FATAL|AndroidRuntime|signal [0-9]+|SIGSEGV|SIGABRT|Fatal signal|ndk_translation|houdini|ANR in|am_crash|am_anr|am_proc_died|dlopen failed|UnsatisfiedLink|cannot locate symbol|EGL|GLES|CameraService|CameraManager|UnknownHost|SSLHandshake|ConnectException|Integrity|SafetyNet|attest|emulator" | grep -viE 'chatty|wifi|bluetooth' | tail -120
}

{
echo "id: $ID"
echo "run: ${RUN_ID:-?}   utc: $(date -u +%FT%TZ)"
echo "=== device identity (what the app can see) ==="
for k in ro.build.version.release ro.build.version.sdk ro.product.model ro.product.manufacturer ro.product.brand ro.hardware ro.kernel.qemu ro.build.fingerprint ro.build.tags ro.build.type ro.debuggable ro.product.cpu.abilist ro.dalvik.vm.native.bridge ro.dalvik.vm.isa.arm64 ro.dalvik.vm.isa.arm ro.boot.qemu ro.adb.secure persist.sys.timezone; do echo "$k = $(A getprop $k)"; done
echo "=== google services ==="
for p in com.google.android.gms com.android.vending com.google.android.webview com.android.chrome; do echo "$p: $(A dumpsys package $p | grep -m1 versionName)"; done
echo "=== emulator config (host side) ==="
grep -iE 'camera|gpu|ram|ncore|heap|abi|image.sysdir|tag.id|audio|sdcard' "$HOME/.android/avd/persistent_avd.avd/config.ini" 2>&1 | head -30
echo "emulator cmdline:"; ps -eo args | grep -E 'qemu-system|emulator' | grep -v grep | cut -c1-500 | head -3
echo "=== network inside the phone ==="
A ping -c 2 -W 3 8.8.8.8 | tail -3
A ping -c 2 -W 3 snapchat.com | tail -3
A ping -c 2 -W 3 www.tiktok.com | tail -3
echo "dns: $(A getprop net.dns1) $(A getprop net.dns2)"
A settings get global airplane_mode_on
A dumpsys connectivity | grep -iE 'validated|NOT_METERED' | head -4
A settings get global http_proxy
echo "=== date/time inside the phone (a wrong clock breaks TLS) ==="; A date; date -u
echo "=== memory ==="; A cat /proc/meminfo | head -3
echo "=== camera service ==="; A dumpsys media.camera | head -25
echo "=== OpenGL renderer ==="; A dumpsys SurfaceFlinger | grep -iE 'GLES|OpenGL' | head -3
run_app com.snapchat.android
TT=$(A pm list packages | grep -oE 'com\.(zhiliaoapp\.musically|ss\.android\.ugc\.trill)' | head -1)
[ -n "$TT" ] && run_app $TT || echo "TikTok package not found"
A input keyevent KEYCODE_HOME
echo "=== diag finished $(date -u +%T) ==="
} 2>&1 | red | head -c 60000 > "$OUT"
echo "app-diag $ID written to $OUT ($(wc -c < "$OUT") bytes)"
