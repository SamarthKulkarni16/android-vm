#!/bin/bash
# CEO 2026-10-20: session script (runs inside the emulator action after the phone has booted).
# Opens the tunnel, keeps the phone alive until the 5 hour limit OR a stop request (the X button in the launcher),
# saves the phone state (encrypted) periodically and cleanly at the end.
cd "${GITHUB_WORKSPACE:-.}" 2>/dev/null || true
mkdir -p logs
export LOGF=/tmp/full-script.log
source ./avd-lib.sh
START=${SESSION_START:-$(date +%s)}
END=$(( START + 18000 ))   # 5 hours after the workflow started
HOSTPORT=""
touch /tmp/session-booted
git config user.name "github-actions"; git config user.email "actions@github.com"

gpush() { git add logs >> $LOGF 2>&1; git commit -m "$1" >> $LOGF 2>&1 || return 0; git pull --rebase origin main -q >> $LOGF 2>&1 || true; git push >> $LOGF 2>&1 || true; }

set_state() {  # $1 = state, $2 = note
  { echo "run_id: ${RUN_ID}"; echo "v: 2"; echo "state: $1"; [ -n "$2" ] && echo "note: $2"
    echo "updated: $(date -u +%FT%TZ)"; echo "ends_utc: $(date -u -d @$END +%FT%TZ)"; } > logs/session-state.txt
  cp $LOGF logs/full-script-latest.txt
  gpush "state $1 run ${RUN_ID}"
}

stop_requested() {
  local c
  c=$(gh api "repos/${GITHUB_REPOSITORY}/contents/logs/stop-request.txt" -H 'Accept: application/vnd.github.raw' 2>/dev/null) || return 1
  echo "$c" | grep -q "^run_id: ${RUN_ID}\$"
}

echo "=== session script start $(date -u), run ${RUN_ID}, ends $(date -u -d @$END) ===" >> $LOGF
adb devices -l >> $LOGF 2>&1 || true

# CEO 2026-10-27: classic 3-button navigation bar (Back triangle, Home circle, Recents square) instead of gestures.
# Saved with the phone, repeated on every boot to be safe.
( adb shell cmd overlay enable com.android.internal.systemui.navbar.threebutton >> $LOGF 2>&1 || true
  adb shell settings put secure navigation_mode 0 >> $LOGF 2>&1 || true
  echo "[nav] 3-button navigation requested" >> $LOGF ) &

# accept the adb 'Allow USB debugging' dialog for trusted keys (production image, no root); runs in the background
(
  no_dialog=0
  for i in $(seq 1 720); do
    adb shell input keyevent KEYCODE_WAKEUP >> $LOGF 2>&1 || true
    DUMP=$(adb shell uiautomator dump /sdcard/window_dump.xml >/dev/null 2>&1 && adb shell cat /sdcard/window_dump.xml 2>/dev/null)
    if echo "$DUMP" | grep -qiE 'allow|always allow'; then
      no_dialog=0
      BOUNDS=$(echo "$DUMP" | grep -oE 'text="Allow[^"]*"[^>]*bounds="\[[0-9]+,[0-9]+\]\[[0-9]+,[0-9]+\]"' | head -1 | grep -oE '\[[0-9]+,[0-9]+\]\[[0-9]+,[0-9]+\]')
      if [ -n "$BOUNDS" ]; then
        X1=$(echo "$BOUNDS" | sed -E 's/\[([0-9]+),([0-9]+)\]\[([0-9]+),([0-9]+)\]/\1/'); Y1=$(echo "$BOUNDS" | sed -E 's/\[([0-9]+),([0-9]+)\]\[([0-9]+),([0-9]+)\]/\2/')
        X2=$(echo "$BOUNDS" | sed -E 's/\[([0-9]+),([0-9]+)\]\[([0-9]+),([0-9]+)\]/\3/'); Y2=$(echo "$BOUNDS" | sed -E 's/\[([0-9]+),([0-9]+)\]\[([0-9]+),([0-9]+)\]/\4/')
        adb shell input tap $(( (X1 + X2) / 2 )) $(( (Y1 + Y2) / 2 )) >> $LOGF 2>&1 || true
        echo "[watcher] tapped Allow" >> $LOGF
      else
        adb shell input keyevent KEYCODE_TAB >> $LOGF 2>&1 || true; adb shell input keyevent KEYCODE_TAB >> $LOGF 2>&1 || true; adb shell input keyevent KEYCODE_ENTER >> $LOGF 2>&1 || true
      fi
    else
      no_dialog=$((no_dialog + 1))
      if [ $no_dialog -gt 180 ]; then adb shell 'rm -f /sdcard/window_dump.xml' >> $LOGF 2>&1 || true; exit 0; fi
    fi
    sleep 5
  done
) &

echo "=== opening ngrok tcp tunnel ===" >> $LOGF
nohup ngrok tcp 5555 --log=stdout > /tmp/ngrok.log 2>&1 &
sleep 6
ADDR=""
for i in 1 2 3 4 5 6 7 8 9 10; do
  ADDR=$(curl -s http://localhost:4040/api/tunnels 2>/dev/null | python3 -c "import sys,json;d=json.load(sys.stdin);print(d['tunnels'][0]['public_url'])" 2>/dev/null || echo "")
  [ -n "$ADDR" ] && break
  sleep 3
done
HOSTPORT=$(echo "$ADDR" | sed 's#tcp://##')
echo "adb connect $HOSTPORT" >> $LOGF
{ echo "adb connect $HOSTPORT"; echo "run_id: ${RUN_ID}"; echo "v: 2"; echo "state: running"; echo "generated: $(date -u)"; echo "ends_utc: $(date -u -d @$END +%FT%TZ)"; } > logs/connect-now.txt
set_state running "phone ready"

# CEO 2026-10-26: one-shot Snapchat/TikTok diagnostics, only when logs/app-diag-request.txt asks for it (read-only, redacted)
if [ -f app-diag.sh ] && [ -f logs/app-diag-request.txt ]; then ( RUN_ID=${RUN_ID} bash app-diag.sh >> $LOGF 2>&1; gpush "app diag run ${RUN_ID}" ) & fi

SAVEPID=""; LAST_SAVE=$(date +%s); DEAD=0; REASON=""
while true; do
  NOW=$(date +%s)
  if [ $NOW -ge $END ]; then REASON="5 hour limit reached"; break; fi
  if stop_requested; then REASON="close button (X) pressed"; break; fi
  if adb get-state 2>/dev/null | grep -q device; then DEAD=0; else DEAD=$((DEAD+1)); fi
  if [ $DEAD -ge 9 ]; then REASON="emulator stopped by itself"; break; fi
  if [ -n "$SAVEPID" ] && ! kill -0 $SAVEPID 2>/dev/null; then wait $SAVEPID 2>/dev/null; SAVEPID=""; gpush "periodic save done run ${RUN_ID}"; fi
  if [ -z "$SAVEPID" ] && [ $((NOW - LAST_SAVE)) -ge 1200 ]; then save_state g & SAVEPID=$!; LAST_SAVE=$NOW; fi
  sleep 10
done

echo "=== stopping: $REASON at $(date -u) ===" >> $LOGF
set_state saving "$REASON"
if [ -n "$SAVEPID" ]; then pkill -f /tmp/avdparts 2>/dev/null; kill $SAVEPID 2>/dev/null; wait $SAVEPID 2>/dev/null; fi
KIND=c
if [ "$REASON" = "emulator stopped by itself" ]; then
  KIND=g
else
  adb shell sync >> $LOGF 2>&1 || true
  adb emu kill >> $LOGF 2>&1 || true
  for i in $(seq 1 60); do pgrep -f qemu-system >/dev/null || break; sleep 2; done
  sleep 3
fi
if save_state $KIND; then touch /tmp/final-save-done; fi
[ -f /tmp/save-allowed ] || touch /tmp/final-save-done
set_state ended "$REASON"
echo "=== session script finished $(date -u) ===" >> $LOGF
