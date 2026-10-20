#!/bin/bash
# Restores the newest good saved phone state (see avd-lib.sh). Never fails the job: a blank phone is better than no session.
source ./avd-lib.sh
restore_state || true
if [ -f /tmp/save-allowed ]; then echo "restore result: OK (saving enabled)"; else echo "restore result: FAILED (saving disabled)"; fi
ls -la ~/.android/avd 2>/dev/null
df -h / | tail -1
exit 0
