#!/bin/bash
# Android Live launcher v2 (CEO 2026-10-20), the target of the desktop icon on the VM.
# Starts (or reuses) the cloud phone, connects scrcpy. When you close the phone window (X) it tells the cloud phone to
# save your data and shut down; the cloud phone also shuts itself down at the 5 hour limit, whichever is first.
TOKEN_FILE="$HOME/.config/android-live/token"
REPO="SamarthKulkarni16/android-vm"
API="https://api.github.com/repos/$REPO"
if [ ! -f "$TOKEN_FILE" ]; then echo "No GitHub token found at $TOKEN_FILE - setup is incomplete."; read -p "Press Enter to close..."; exit 1; fi
GH_TOKEN=$(cat "$TOKEN_FILE")
H1="Authorization: token $GH_TOKEN"; H2="Accept: application/vnd.github+json"
gh_api() { curl -s -H "$H1" -H "$H2" "$@"; }
raw() { curl -s -H "$H1" -H "Accept: application/vnd.github.raw" "$API/contents/$1?ref=main&t=$(date +%s)"; }
RUN_ID=""; STOPPED=0; V2=0

latest_runs() {
  gh_api "$API/actions/workflows/android-live.yml/runs?per_page=6" | python3 -c "
import sys, json
d = json.load(sys.stdin)
for r in d.get('workflow_runs', []):
    print(r['id'], r['status'], r.get('conclusion') or '-', r['created_at'])
" 2>/dev/null
}
state_of() {  # state of run $1 from logs/session-state.txt ('' if that file belongs to another run)
  local c; c=$(raw logs/session-state.txt)
  echo "$c" | grep -q "^run_id: $1\$" && echo "$c" | grep '^state:' | head -1 | sed 's/state: //'
}
is_v2() { raw logs/session-state.txt | grep -q "^run_id: $1\$" && raw logs/session-state.txt | grep -q '^v: 2'; }

request_stop() {
  [ "$STOPPED" = 1 ] && return
  [ -z "$RUN_ID" ] && return
  if [ "$V2" != 1 ]; then
    echo; echo "This cloud phone was started by the OLD version, so it cannot be closed from here. It keeps running until its own 5 hour limit; click the icon again to reconnect."
    return
  fi
  STOPPED=1
  echo; echo "Closing the cloud phone: asking it to save your data and shut down..."
  local sha body
  sha=$(gh_api "$API/contents/logs/stop-request.txt?ref=main" | python3 -c "import sys,json;print(json.load(sys.stdin).get('sha',''))" 2>/dev/null)
  body=$(printf 'run_id: %s\nrequested: %s\n' "$RUN_ID" "$(date -u +%FT%TZ)" | base64 -w0)
  python3 - "$body" "$sha" > /tmp/android-live-stop.json <<'PY'
import sys, json
d = {"message": "stop request", "content": sys.argv[1], "branch": "main"}
if sys.argv[2]: d["sha"] = sys.argv[2]
print(json.dumps(d))
PY
  curl -s -X PUT -H "$H1" -H "$H2" "$API/contents/logs/stop-request.txt" -d @/tmp/android-live-stop.json > /dev/null
}
trap 'request_stop; exit 0' HUP TERM

echo "=== Android Live ==="
while true; do
  ACTIVE=$(latest_runs | awk '$2=="in_progress"||$2=="queued"||$2=="waiting"||$2=="pending"{print $1" "$2; exit}')
  if [ -z "$ACTIVE" ]; then
    T0=$(date -u -d '40 seconds ago' +%FT%TZ)
    echo "No active session - starting one now (boot takes about 5-8 minutes because your saved phone is restored first)..."
    curl -s -X POST -H "$H1" -H "$H2" "$API/actions/workflows/android-live.yml/dispatches" -d '{"ref":"main"}' > /dev/null
    for i in $(seq 1 30); do sleep 4; RUN_ID=$(latest_runs | awk -v t="$T0" '$4>=t{print $1; exit}'); [ -n "$RUN_ID" ] && break; done
    [ -z "$RUN_ID" ] && { echo "Could not find the new run - check https://github.com/$REPO/actions"; read -p "Press Enter to close..."; exit 1; }
    break
  fi
  RID=${ACTIVE%% *}
  ST=$(state_of "$RID")
  case "$ST" in
    saving|ended) echo "The previous session is still saving your data - waiting for it to finish (run $RID)..."; sleep 15; continue ;;
  esac
  RUN_ID=$RID; echo "Found a running session (run $RID, state: ${ST:-unknown}) - connecting to it."; break
done

echo "Waiting for the phone to be ready..."
ADDR=""; ENDS=""
for i in $(seq 1 360); do
  C=$(raw logs/connect-now.txt)
  if echo "$C" | grep -q "^run_id: $RUN_ID\$" && echo "$C" | grep -q '^adb connect '; then
    ADDR=$(echo "$C" | grep '^adb connect ' | head -1 | sed 's/adb connect //')
    ENDS=$(echo "$C" | grep '^ends_utc:' | head -1 | sed 's/ends_utc: //')
    break
  fi
  if [ $((i % 12)) -eq 0 ]; then
    RS=$(latest_runs | awk -v r="$RUN_ID" '$1==r{print $2" "$3}')
    echo "  still starting... $((i*5/60)) min (run status: $RS)"
    case "$RS" in completed*) echo "The cloud run ended before the phone was ready: https://github.com/$REPO/actions/runs/$RUN_ID"; read -p "Press Enter to close..."; exit 1 ;; esac
  fi
  sleep 5
done
if [ -z "$ADDR" ]; then echo "Could not get a connect address - check https://github.com/$REPO/actions"; read -p "Press Enter to close..."; exit 1; fi
is_v2 "$RUN_ID" && V2=1

while true; do
  HOSTPORT=$ADDR
  echo "Connecting adb to $HOSTPORT ..."
  adb kill-server > /dev/null 2>&1
  adb connect "$HOSTPORT"; sleep 2; adb devices
  if [ "$V2" = 1 ]; then echo "Your phone is ready. It shuts down automatically at ${ENDS:-the 5 hour limit} or when you close the phone window (X). Your apps and data are saved either way."
  else echo "Your phone is ready (old-style session: it runs until its own 5 hour limit)."; fi
  echo "Launching scrcpy..."
  scrcpy; RC=$?
  if [ $RC -eq 0 ]; then request_stop; break; fi
  echo "scrcpy stopped with an error (exit $RC) - maybe a network hiccup."
  read -p "Press Enter to reconnect, or type s then Enter to stop the cloud phone: " ans
  if [ "$ans" = "s" ]; then request_stop; break; fi
done

if [ "$STOPPED" = 1 ]; then
  echo "Saving your phone to the cloud (about 4-8 minutes). Keep this window open until it says SAVED..."
  for i in $(seq 1 180); do
    ST=$(gh_api "$API/actions/runs/$RUN_ID" | python3 -c "import sys,json;d=json.load(sys.stdin);print(d.get('status',''),d.get('conclusion') or '')" 2>/dev/null)
    case "$ST" in completed*) break ;; esac
    echo "  $(date +%H:%M:%S) $(state_of "$RUN_ID") ..."
    sleep 10
  done
  case "$ST" in
    "completed success") echo "SAVED. The cloud phone is off. Next time it continues from exactly here. You can close this window." ;;
    *) echo "The session ended ($ST). Check https://github.com/$REPO/actions/runs/$RUN_ID . Your previous saved copy is still safe." ;;
  esac
fi
