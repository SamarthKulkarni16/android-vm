#!/bin/bash
# Restores the newest good saved phone state (see avd-lib.sh). Never fails the job: a blank phone is better than no session.
# CEO 2026-11-18: free runner disk first (the saved phone is several GB and now grows to a 16 GB data partition).
( sudo rm -rf /usr/share/dotnet /opt/ghc /usr/local/share/boost /opt/hostedtoolcache/CodeQL /usr/local/.ghcup /usr/share/swift >/dev/null 2>&1 ) &
FREEPID=$!
source ./avd-lib.sh
restore_state || true
if [ -f /tmp/save-allowed ]; then echo "restore result: OK (saving enabled)"; else echo "restore result: FAILED (saving disabled)"; fi
wait $FREEPID 2>/dev/null

# CEO 2026-10-27: the 10-27 diagnosis showed the phone ran starved (2 GB RAM, 64 MB app heap, swap thrashing).
# The workflow only sets the CPU core count, so RAM and heap are set here, in the phone's own config.ini, before it boots.
# CEO 2026-11-18: data partition 16 GB (was full with TikTok + Snapchat) and the on-screen navigation bar must not be hidden.
C="$HOME/.android/avd/persistent_avd.avd/config.ini"
if [ -f "$C" ]; then
  for kv in hw.ramSize=4096M vm.heapSize=512M hw.camera.front=emulated disk.dataPartition.size=16G hw.mainKeys=no; do
    k="${kv%%=*}"
    sed -i "/^${k} *=/d" "$C"
    echo "$kv" >> "$C"
  done
  echo "phone hardware config now:"; grep -E 'ramSize|heapSize|ncore|camera|dataPartition|mainKeys' "$C"
  bash ./resize-userdata.sh 16 || true
fi

ls -la ~/.android/avd 2>/dev/null
df -h / | tail -1
exit 0
