#!/bin/bash
# CEO 2026-10-20: shared helpers to save and restore the phone (AVD).
# The repo is PUBLIC, so the phone data is ALWAYS encrypted (AES-256) before it is uploaded.
# Generation ids: lowercase g = periodic save (taken while the phone runs), c = clean save (phone stopped first).
# Uppercase G/C = old unencrypted saves from before 2026-10-20 (restored once, then replaced by an encrypted copy).
REL=avd-state
AVD_DIR=$HOME/.android/avd
LOGF=${LOGF:-/tmp/full-script.log}

avd_pass() {
  if [ -n "$AVD_STATE_KEY" ]; then printf '%s' "$AVD_STATE_KEY"
  elif [ -n "$ADB_PRIVATE_KEY" ]; then printf '%s' "$ADB_PRIVATE_KEY" | sha256sum | cut -d' ' -f1
  fi
}

avd_assets() { gh release view $REL --json assets --jq '.assets[].name' 2>/dev/null; }

# complete generations only (all parts present), oldest first
avd_list_gens() {
  avd_assets | grep -oE '^avd-[GCgc][0-9T]+-p[0-9]+of[0-9]+$' | sed -E 's/^avd-([GCgc][0-9T]+)-p([0-9]+)of([0-9]+)$/\1 \3/' | sort | uniq -c | awk '{ if ($1==$3) print $2 }' | sort -k1.2
}

save_state() {  # $1 = g (periodic) or c (clean)
  local K=${1:-g} GEN D=/tmp/avdparts N i f a g KEEP RCS
  export AVDK; AVDK=$(avd_pass)
  if [ -z "$AVDK" ]; then echo "save REFUSED: no encryption key available (repo is public)" >> $LOGF; return 1; fi
  if [ ! -f /tmp/save-allowed ]; then echo "save skipped: restore did not succeed, protecting the old saved data" >> $LOGF; return 1; fi
  if [ ! -d $AVD_DIR/persistent_avd.avd ]; then echo "save skipped: no AVD folder" >> $LOGF; return 1; fi
  GEN="$K$(date -u +%Y%m%dT%H%M)"
  echo "=== saving phone state $GEN (encrypted) at $(date -u) ===" >> $LOGF
  if [ "$K" = g ]; then adb shell sync >> $LOGF 2>&1 || true; fi
  rm -rf $D; mkdir -p $D
  tar czf - -C $AVD_DIR persistent_avd.avd persistent_avd.ini 2>>$LOGF | openssl enc -aes-256-cbc -pbkdf2 -salt -pass env:AVDK 2>>$LOGF | split -b 1800M -d -a 2 - $D/part-
  RCS=("${PIPESTATUS[@]}")
  N=$(ls $D | wc -l)
  # tar exit 1 = file changed while reading: expected for a live copy. Only 2+ is a real failure.
  if [ "${RCS[0]}" -gt 1 ] || [ "${RCS[1]}" -ne 0 ] || [ "$N" -lt 1 ]; then
    echo "save FAILED (tar ${RCS[0]}, openssl ${RCS[1]}, parts $N), old state kept" >> $LOGF; rm -rf $D; return 1
  fi
  i=0
  for f in $(ls $D | sort); do i=$((i+1)); mv "$D/$f" "$D/avd-$GEN-p${i}of${N}"; done
  ls -l $D >> $LOGF
  gh release view $REL >/dev/null 2>&1 || gh release create $REL --title "AVD persistent state (encrypted)" --notes "auto-managed, encrypted, do not edit" >> $LOGF 2>&1
  if gh release upload $REL $D/avd-$GEN-p* >> $LOGF 2>&1; then
    # keep this generation + the newest other CLEAN generation; everything else (old, partial, unencrypted) goes
    KEEP="$GEN $(avd_list_gens | grep -E '^[Cc]' | grep -vx "$GEN" | tail -1)"
    for a in $(avd_assets); do
      g=${a#avd-}; g=${g%%-p*}
      case " $KEEP " in *" $g "*) ;; *) gh release delete-asset $REL "$a" -y >> $LOGF 2>&1 ;; esac
    done
    echo "save ok $GEN at $(date -u); kept: $KEEP" >> $LOGF
    rm -rf $D; return 0
  else
    echo "UPLOAD FAILED, old state kept" >> $LOGF; rm -rf $D; return 1
  fi
}

restore_state() {
  local GENS G N i IMG rc DEC
  mkdir -p $AVD_DIR; rm -f /tmp/save-allowed
  GENS=$(avd_list_gens | tac)
  if [ -z "$GENS" ]; then echo "No saved phone state yet (first run)."; touch /tmp/save-allowed; return 0; fi
  echo "saved generations (newest first): $(echo $GENS)"
  export AVDK; AVDK=$(avd_pass)
  sudo apt-get install -y qemu-utils >/dev/null 2>&1 || true
  for G in $GENS; do
    N=$(avd_assets | grep -E "^avd-$G-p[0-9]+of[0-9]+$" | head -1 | sed -E 's/.*of([0-9]+)$/\1/')
    echo "Trying saved state $G ($N parts)"
    rm -rf $AVD_DIR/persistent_avd.avd $AVD_DIR/persistent_avd.ini
    if [[ "$G" =~ ^[a-z] ]]; then DEC="openssl enc -d -aes-256-cbc -pbkdf2 -pass env:AVDK"; else DEC="cat"; fi
    ( set -o pipefail; for i in $(seq 1 $N); do gh release download $REL -p "avd-$G-p${i}of${N}" -O - ; done | $DEC | tar xz -C $AVD_DIR )
    if [ $? -ne 0 ]; then echo "  could not unpack $G"; continue; fi
    IMG=$AVD_DIR/persistent_avd.avd/userdata-qemu.img.qcow2
    if [ ! -f "$IMG" ]; then echo "  no userdata image inside $G"; continue; fi
    if command -v qemu-img >/dev/null 2>&1; then
      qemu-img check "$IMG" > /tmp/qcheck.txt 2>&1; rc=$?
      if [ $rc -ne 0 ] && [ $rc -ne 3 ]; then qemu-img check -r all "$IMG" >> /tmp/qcheck.txt 2>&1; rc=$?; fi
      tail -3 /tmp/qcheck.txt
      if [ $rc -ne 0 ] && [ $rc -ne 3 ]; then echo "  image of $G is damaged and could not be repaired"; continue; fi
      if [ $rc -eq 3 ]; then qemu-img check -r leaks "$IMG" >/dev/null 2>&1; fi
    else
      echo "  qemu-img not available, skipping the integrity check"
    fi
    echo "RESTORED $G"; touch /tmp/save-allowed
    if [[ "$G" =~ ^[A-Z] ]]; then echo "migrating the old unencrypted save to an encrypted one..."; save_state c; fi
    return 0
  done
  rm -rf $AVD_DIR/persistent_avd.avd $AVD_DIR/persistent_avd.ini
  echo "ALL saved states failed to restore: starting with a blank phone and saving is DISABLED this session so your old data is not overwritten"
  return 1
}
