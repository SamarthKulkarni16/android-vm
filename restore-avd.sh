#!/bin/bash
# Restores the newest COMPLETE generation of the AVD state (parts), or the old single file.
mkdir -p ~/.android/avd /tmp/avdrestore
if ! gh release view avd-state --json assets --jq '.assets[].name' > /tmp/assets.txt 2>/tmp/gh-dl-err.txt; then
  echo "No prior state (no release yet):"; cat /tmp/gh-dl-err.txt; exit 0
fi
echo "assets:"; cat /tmp/assets.txt
G=$(grep -oE '^avd-G[0-9T]+-p[0-9]+of[0-9]+$' /tmp/assets.txt | sed -E 's/^avd-(G[0-9T]+)-p([0-9]+)of([0-9]+)$/\1 \3/' | sort | uniq -c | awk '{ if ($1==$3) print $2 }' | sort | tail -1)
if [ -n "$G" ]; then
  echo "Restoring generation $G"
  gh release download avd-state -p "avd-$G-p*" -D /tmp/avdrestore --clobber && cat $(ls /tmp/avdrestore/avd-$G-p* | sort -V) | tar xz -C ~/.android/avd && echo "restored $G"
elif grep -qx 'avd-state.tar.gz' /tmp/assets.txt; then
  echo "Restoring legacy single file"
  gh release download avd-state -p 'avd-state.tar.gz' -O /tmp/avd-state.tar.gz --clobber && tar xzf /tmp/avd-state.tar.gz -C ~/.android/avd && echo "restored legacy"
else
  echo "No prior state found"
fi
ls -la ~/.android/avd
