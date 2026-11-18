#!/bin/bash
# CEO 2026-11-18: grow the phone's data partition to TARGET GB and keep all data (no wipe).
# Runs on the GitHub runner after the saved phone is restored and BEFORE it boots. Never fails the job.
TARGET_G=${1:-16}
IMG=$HOME/.android/avd/persistent_avd.avd/userdata-qemu.img.qcow2
if [ ! -f "$IMG" ]; then echo "[storage] no userdata image (blank phone), nothing to resize"; exit 0; fi
sudo apt-get install -y qemu-utils e2fsprogs f2fs-tools >/dev/null 2>&1 || true
WANT=$((TARGET_G*1024*1024*1024))
CUR=$(qemu-img info --output=json "$IMG" 2>/dev/null | python3 -c "import sys,json;print(json.load(sys.stdin)['virtual-size'])" 2>/dev/null || echo 0)
echo "[storage] image size before: $((CUR/1048576)) MB, target ${TARGET_G} GB"
if [ "$CUR" -gt 0 ] && [ "$CUR" -lt "$WANT" ]; then
  qemu-img resize "$IMG" "${TARGET_G}G" || { echo "[storage] qemu-img resize failed, leaving the phone as it was"; exit 0; }
fi
sudo modprobe nbd max_part=0 2>/dev/null || true
if [ ! -e /dev/nbd0 ]; then echo "[storage] no /dev/nbd0 on this runner: image grown but the file system inside was not"; exit 0; fi
sudo qemu-nbd -d /dev/nbd0 >/dev/null 2>&1 || true
if ! sudo qemu-nbd --format=qcow2 --connect=/dev/nbd0 "$IMG"; then echo "[storage] qemu-nbd connect failed"; exit 0; fi
for i in 1 2 3 4 5 6 7 8 9 10; do sudo blkid /dev/nbd0 >/dev/null 2>&1 && break; sleep 1; done
FST=$(sudo blkid -o value -s TYPE /dev/nbd0 2>/dev/null)
echo "[storage] file system inside the phone image: ${FST:-unknown (encrypted or unreadable)}"
case "$FST" in
  ext4)
    sudo e2fsck -fy /dev/nbd0; echo "[storage] e2fsck exit $?"
    sudo resize2fs /dev/nbd0; echo "[storage] resize2fs exit $?" ;;
  f2fs)
    sudo fsck.f2fs -f /dev/nbd0; echo "[storage] fsck.f2fs exit $?"
    sudo resize.f2fs /dev/nbd0; echo "[storage] resize.f2fs exit $?" ;;
  *) echo "[storage] cannot resize this file system type, left as it was" ;;
esac
sync; sudo qemu-nbd -d /dev/nbd0 >/dev/null 2>&1 || true
sleep 2
qemu-img check "$IMG" 2>&1 | tail -2
echo "[storage] resize step finished"
exit 0
