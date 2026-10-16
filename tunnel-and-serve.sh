#!/bin/bash
set -x
mkdir -p logs

save_state() {
  GEN="G$(date -u +%Y%m%dT%H%M)"
  D=/tmp/avdparts
  echo "=== saving AVD state $GEN to GitHub Release in parts ===" >> /tmp/full-script.log
  adb shell sync >> /tmp/full-script.log 2>&1 || true
  rm -rf $D; mkdir -p $D
  tar czf - -C ~/.android/avd persistent_avd.avd persistent_avd.ini 2>>/tmp/full-script.log | split -b 1800M -d -a 2 - $D/part-; TS=${PIPESTATUS[0]}
  N=$(ls $D | wc -l)
  if [ "$TS" -gt 1 ] || [ "$N" -lt 1 ]; then echo "save FAILED (tar exit $TS, parts $N), old state kept" >> /tmp/full-script.log; rm -rf $D; return; fi
  i=0
  for f in $(ls $D | sort); do i=$((i+1)); mv "$D/$f" "$D/avd-$GEN-p${i}of${N}"; done
  ls -l $D >> /tmp/full-script.log
  gh release view avd-state >/dev/null 2>&1 || gh release create avd-state --title "AVD persistent state" --notes "auto-managed, do not edit" >> /tmp/full-script.log 2>&1
  if gh release upload avd-state $D/avd-$GEN-p* >> /tmp/full-script.log 2>&1; then
    for a in $(gh release view avd-state --json assets --jq '.assets[].name'); do
      case "$a" in avd-$GEN-p*) ;; *) gh release delete-asset avd-state "$a" -y >> /tmp/full-script.log 2>&1 ;; esac
    done
    echo "save ok $GEN at $(date -u)" >> /tmp/full-script.log
  else
    echo "UPLOAD FAILED, old state kept" >> /tmp/full-script.log
  fi
  rm -rf $D
}

echo "=== confirm emulator is up ===" >> /tmp/full-script.log
adb devices -l >> /tmp/full-script.log 2>&1 || true
adb shell getprop ro.adb.secure >> /tmp/full-script.log 2>&1 || true
adb exec-out screencap -p > logs/screen-boot.png 2>>/tmp/full-script.log || true
ls -la logs/ >> /tmp/full-script.log 2>&1 || true

echo "=== authorizing trusted adb keys (production image, no root) ===" >> /tmp/full-script.log
# google_apis_playstore is a production build: adb root is unavailable.
# Instead, watch for the 'Allow USB debugging' RSA dialog and accept it via
# the runner's authorized adb, so PC keys get whitelisted and persist in the
# AVD state.
(
  no_dialog=0
  for i in $(seq 1 720); do  # up to 1h of watching
    adb shell input keyevent KEYCODE_WAKEUP >> /tmp/full-script.log 2>&1 || true
    DUMP=$(adb shell uiautomator dump /sdcard/window_dump.xml >/dev/null 2>&1 && adb shell cat /sdcard/window_dump.xml 2>/dev/null)
    if echo "$DUMP" | grep -qiE 'allow|always allow'; then
      no_dialog=0
      echo "[watcher] adb auth dialog detected, accepting..." >> /tmp/full-script.log
      # Find the Allow button bounds: text=Allow ... bounds="[x1,y1][x2,y2]"
      BOUNDS=$(echo "$DUMP" | grep -oE 'text="Allow[^"]*"[^>]*bounds="\[[0-9]+,[0-9]+\]\[[0-9]+,[0-9]+\]"' | head -1 | grep -oE '\[[0-9]+,[0-9]+\]\[[0-9]+,[0-9]+\]')
      if [ -n "$BOUNDS" ]; then
        X1=$(echo "$BOUNDS" | sed -E 's/\[([0-9]+),([0-9]+)\]\[([0-9]+),([0-9]+)\]/\1/')
        Y1=$(echo "$BOUNDS" | sed -E 's/\[([0-9]+),([0-9]+)\]\[([0-9]+),([0-9]+)\]/\2/')
        X2=$(echo "$BOUNDS" | sed -E 's/\[([0-9]+),([0-9]+)\]\[([0-9]+),([0-9]+)\]/\3/')
        Y2=$(echo "$BOUNDS" | sed -E 's/\[([0-9]+),([0-9]+)\]\[([0-9]+),([0-9]+)\]/\4/')
        CX=$(( (X1 + X2) / 2 ))
        CY=$(( (Y1 + Y2) / 2 ))
        adb shell input tap $CX $CY >> /tmp/full-script.log 2>&1 || true
        echo "[watcher] tapped Allow at $CX,$CY" >> /tmp/full-script.log
      else
        adb shell input keyevent KEYCODE_TAB >> /tmp/full-script.log 2>&1 || true
        adb shell input keyevent KEYCODE_TAB >> /tmp/full-script.log 2>&1 || true
        adb shell input keyevent KEYCODE_ENTER >> /tmp/full-script.log 2>&1 || true
        echo "[watcher] pressed TAB TAB ENTER fallback" >> /tmp/full-script.log
      fi
    else
      no_dialog=$((no_dialog + 1))
      # After several empty checks, a currently-connected peer is authorized.
      if [ $no_dialog -gt 180 ]; then  # ~15 min idle
        adb shell 'rm -f /sdcard/window_dump.xml' >> /tmp/full-script.log 2>&1 || true
        exit 0
      fi
    fi
    sleep 5
  done
  adb shell 'rm -f /sdcard/window_dump.xml' >> /tmp/full-script.log 2>&1 || true
) &

git config user.name "github-actions"
git config user.email "actions@github.com"
cp /tmp/full-script.log logs/full-script-latest.txt
git add logs/full-script-latest.txt
git commit -m "checkpoint 1 (post-boot) for run ${RUN_ID}" || true
git pull --rebase origin main -q || true
git push || true

echo "=== opening ngrok tcp tunnel ===" >> /tmp/full-script.log
nohup ngrok tcp 5555 --log=stdout > /tmp/ngrok.log 2>&1 &
sleep 6
ADDR=""
for i in 1 2 3 4 5 6 7 8 9 10; do
  ADDR=$(curl -s http://localhost:4040/api/tunnels 2>/dev/null | python3 -c "import sys,json;d=json.load(sys.stdin);print(d['tunnels'][0]['public_url'])" 2>/dev/null || echo "")
  if [ -n "$ADDR" ]; then
    echo "got address on attempt $i" >> /tmp/full-script.log
    break
  fi
  echo "attempt $i: no address yet" >> /tmp/full-script.log
  sleep 3
done
echo "ADDR is: $ADDR" >> /tmp/full-script.log
echo "=== ngrok's own log ===" >> /tmp/full-script.log
cat /tmp/ngrok.log >> /tmp/full-script.log 2>&1 || true
HOSTPORT=$(echo "$ADDR" | sed 's#tcp://##')
echo "adb connect $HOSTPORT" >> /tmp/full-script.log

echo "=== committing connect address to repo ===" >> /tmp/full-script.log
echo "adb connect $HOSTPORT" > logs/connect-now.txt
echo "run_id: ${RUN_ID}" >> logs/connect-now.txt
echo "generated: $(date -u)" >> logs/connect-now.txt
git add logs/connect-now.txt
git commit -m "connect address for run ${RUN_ID}" >> /tmp/full-script.log 2>&1 || true
git pull --rebase origin main -q >> /tmp/full-script.log 2>&1 || true
git push >> /tmp/full-script.log 2>&1 || true
echo "commit step done" >> /tmp/full-script.log

cp /tmp/full-script.log logs/full-script-latest.txt
git add logs/full-script-latest.txt
git commit -m "checkpoint 2 (post-tunnel) for run ${RUN_ID}" || true
git pull --rebase origin main -q || true
git push || true

echo "=== keeping session alive for ~295 minutes (4h55m), saving state every 20 min ==="
for i in $(seq 1 295); do
  sleep 60
  if [ $((i % 20)) -eq 0 ]; then
    save_state
    cp /tmp/full-script.log logs/full-script-latest.txt
    git add logs/full-script-latest.txt
    git commit -m "periodic checkpoint minute $i for run ${RUN_ID}" || true
    git pull --rebase origin main -q || true
    git push || true
  fi
  echo "alive minute $i/295"
done

echo "=== final state save before session ends (stop emulator first so the disk is consistent) ==="
adb emu kill >> /tmp/full-script.log 2>&1 || true
sleep 25
save_state
cp /tmp/full-script.log logs/full-script-latest.txt
git add logs/full-script-latest.txt
git commit -m "final checkpoint for run ${RUN_ID}" || true
git pull --rebase origin main -q || true
git push || true
