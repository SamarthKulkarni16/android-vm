#!/bin/bash
set -x
mkdir -p logs

save_state() {
  echo "=== saving AVD state to GitHub Release ===" >> /tmp/full-script.log
  tar czf /tmp/avd-state.tar.gz -C ~/.android/avd persistent_avd.avd persistent_avd.ini 2>>/tmp/full-script.log
  gh release upload avd-state /tmp/avd-state.tar.gz --clobber >> /tmp/full-script.log 2>&1 || \
    gh release create avd-state /tmp/avd-state.tar.gz --title "AVD persistent state" --notes "auto-managed, do not edit" >> /tmp/full-script.log 2>&1
  echo "save_state done at $(date -u)" >> /tmp/full-script.log
}

echo "=== confirm emulator is up ===" >> /tmp/full-script.log
adb devices -l >> /tmp/full-script.log 2>&1 || true

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

echo "=== keeping session alive for ~345 minutes (5h45m), saving state every 20 min ==="
for i in $(seq 1 345); do
  sleep 60
  if [ $((i % 20)) -eq 0 ]; then
    save_state
    cp /tmp/full-script.log logs/full-script-latest.txt
    git add logs/full-script-latest.txt
    git commit -m "periodic checkpoint minute $i for run ${RUN_ID}" || true
    git pull --rebase origin main -q || true
    git push || true
  fi
  echo "alive minute $i/345"
done

echo "=== final state save before session ends ==="
save_state
cp /tmp/full-script.log logs/full-script-latest.txt
git add logs/full-script-latest.txt
git commit -m "final checkpoint for run ${RUN_ID}" || true
git pull --rebase origin main -q || true
git push || true
