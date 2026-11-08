# Android-on-QEMU Handoff — 2026-09-06 (for continuing in a new chat)

> HISTORY ONLY. This was the attempt to run Android on the Oracle VM with QEMU TCG. It was abandoned on 2026-09-30; the emulator now runs on a GitHub runner with KVM (this repo). Moved here from the hq repo on 2026-11-08.

## Objective
Get a WORKING Android emulator on an **ARM64 Oracle Cloud VM** (Ubuntu 22.04, no KVM, no binder kernel modules) via `qemu-system-aarch64` with TCG software emulation — with adb shell access, running reliably in background. UI/GPU is secondary; **adb shell + sys.boot_completed is the main win**.

## Environment (fixed facts)
- Host: Oracle Cloud Ubuntu 22.04, ARM64 (aarch64), kernel 6.8.0-1060-oracle, no `/dev/kvm`, no binder modules.
- QEMU 6.2.0, TCG software emulation (slow boot ~10-20 min guest-time is fast, real-time is slower; use `-smp 4`).
- Guest: Android 9-ish (API 28) **ranchu** build, kernel-ranchu 4.4.302.
- **`pkill -x qemu-system-aarch64` is UNRELIABLE** — use `ps aux | grep qemu | grep -v grep` and kill by PID. Or `fuser -k 5555/tcp` for port conflicts.
- **Boot log goes stale across runs** — always `rm -f /tmp/android-boot.log` before relaunch.
- Files live in **`/home/ubuntu/android-qemu/`**.

## The 3 past breakthroughs (do NOT undo)
1. **Rebuilt system partition as `system.raw2`**: original `system.raw` was a full Android rootfs whose real /system content lived in a /system subdir — mounting it at /system gave ELOOP + missing files. Fix: `debugfs -R "rdump /system <dir>"` extracted real content, then built NEW image whose ROOT is that content. **Use system.raw2, NOT system.raw.**
2. **SELinux labels** applied via `security.selinux` xattrs with `setfattr` (script: `/tmp/label_images.py`); uses `/tmp/ramdisk_extract/file_contexts`, prefix `/system` or `/vendor`. Fixed "no domain transition" denials.
3. **fstab via DTB**: kernel needs fstab from device tree (`-dtb`), not from ramdisk alone. See "Current DTB" below.

## THIS SESSION — what was found & fixed (read carefully)

### Fix A: DTB fstab mount points + check flags → NEW FILE `/tmp/virt_fstab_data.dtb`
The ORIGINAL `/tmp/virt_fstab.dtb` had an fstab node named `userdata`, which Android's first-stage init mounts at **`/userdata`**, while init.rc writes to **`/data`** → every `/data` mkdir failed with `Read-only file system` (because rootfs was remounted ro). Also the old DTB had `fsmgr_flags = "wait,formattable,check"` on userdata/cache — `check` forces e2fsck on a fresh image → can fail → ro mount.
Fix: rebuilt DTB (`/tmp/virt_fstab_data.dtb`) with:
- node renamed `userdata` → **`data`** (mount point /data), `compatible = "android,fstab-data"`
- userdata/cache `fsmgr_flags = "wait,formattable"` (**check removed**)
- system/vendor stay `ro,barrier=1`, all else unchanged
**Result: vdd→/cache, vdc→/data, vda→/system now ALL mount cleanly in guest.** (Confirmed in latest boot log.)

### Fix B: ramdisk fstab → NEW FILE `/home/ubuntu/android-qemu/ramdisk6_fixed.img`
Original `fstab.ranchu` in ramdisk also had `wait,check,formattable` for /data and /cache. Removed `check`:
```
/dev/block/vda    /system    ext4    ro,barrier=1                    wait
/dev/block/vdb    /vendor    ext4    ro,barrier=1                    wait
/dev/block/vdc    /data      ext4    nosuid,nodev,barrier=1          wait,formattable
/dev/block/vdd    /cache     ext4    nosuid,nodev,barrier=1          wait,formattable
```
Rebuilt: `cd /tmp/ramdisk6_extract && find . | cpio -o -H newc | gzip -9 > /home/ubuntu/android-qemu/ramdisk6_fixed.img`. Extraction dir: `/tmp/ramdisk6_extract` (from ramdisk6.img via `gzip -d | cpio -i`).

### Fix C: userdata/cache/vendor partition repair
- **userdata.raw** (2GB): was corrupt ("Inodes part of corrupted orphan list"). Recreated: `dd if=/dev/zero bs=1M count=2048 of=userdata.raw && sudo mkfs.ext4 -F -L userdata userdata.raw`. Now mounts rw at /data in guest.
- **cache.raw** (1GB): recreated same way (`-L cache`). Mounts fine.
- **vendor.raw (100MB) — STILL THE CURRENT BLOCKER.** See below.

## CURRENT BLOCKER (last state, 2026-09-06 ~10:30)
Boot log shows:
```
[3.741594] EXT4-fs (vdd): mounted ... /cache  → OK
[3.770585] EXT4-fs (vdc): mounted ... /data   → OK
[3.786655] EXT4-fs (vda): mounted ... /system → OK
[3.790877] EXT4-fs (vdb): VFS: Can't find ext4 filesystem   ← FAIL
[3.792593] init: [libfs_mgr]__mount(source=/dev/block/vdb,target=/vendor,type=ext4)=-1: Invalid argument
[3.796688] init: Failed to mount '/vendor'
→ "Reboot start, rebootTarget: bootloader" (QEMU exits; it's a first-stage-mount watchdog)
```
vendor.raw was already: e2fsck'd, journal added, then **fully rebuilt fresh** (dd+mkfs.ext4+copy original content back+SELinux labels re-applied → 444 labeled, 0 errors) and host mounts it fine. Guest kernel STILL says "Can't find ext4 filesystem".

### Leading hypothesis (UNVERIFIED — try next)
**vendor.raw is too small: 100MB = 96MiB = 24576 blocks @4K**, vs cache 1GB (262144 blocks) / userdata 2GB / system 2.6GB which all mount in-guest. Suspected old-kernel quirk with tiny ext4 geometry on virtio-blk, or a superblock alignment issue on the small drive.
**Next step to try: recreate vendor.raw at 1GB (or 512MB), copy content back, relabel, relaunch:**
```
cd /home/ubuntu/android-qemu
dd if=/dev/zero bs=1M count=1024 of=vendor.raw
sudo mkfs.ext4 -F -L vendor vendor.raw
sudo mount -o loop vendor.raw /tmp/vf
sudo cp -a /tmp/vcontent/. /tmp/vf/        # /tmp/vcontent = saved original content (38MB)
sudo chown -R root:root /tmp/vf
sudo umount /tmp/vf
sudo mount -o loop vendor.raw /tmp/vf
sudo python3 /tmp/label_images.py /tmp/vf /tmp/ramdisk_extract/file_contexts /vendor
sudo umount /tmp/vf
```
(If still failing: `hexdump -C -s 1024 -n 64 vendor.raw` vs cache.raw to compare superblock, and/or try `-o noload` mount flag in fstab, and/or compare `tune2fs -l` output block counts vs `-drive` size.)

## CURRENT WORKING QEMU LAUNCH COMMAND
```bash
cd /home/ubuntu/android-qemu
rm -f /tmp/android-boot.log
nohup setsid qemu-system-aarch64 \
  -machine virt,highmem=off -cpu cortex-a53 -smp 4 -m 4096 \
  -accel tcg,thread=multi \
  -kernel kernel-ranchu -dtb /tmp/virt_fstab_data.dtb \
  -initrd ramdisk6_fixed.img \
  -append "console=ttyAMA0 androidboot.hardware=ranchu qemu=1 androidboot.selinux=permissive" \
  -drive file=system.raw2,format=raw,if=none,id=system -device virtio-blk-device,drive=system,serial=vda \
  -drive file=vendor.raw,format=raw,if=none,id=vendor -device virtio-blk-device,drive=vendor,serial=vdb \
  -drive file=userdata.raw,format=raw,if=none,id=userdata -device virtio-blk-device,drive=userdata,serial=vdc \
  -drive file=cache.raw,format=raw,if=none,id=cache -device virtio-blk-device,drive=cache,serial=vdd \
  -netdev user,id=net0,hostfwd=tcp::5555-:5555 -device virtio-net-pci,netdev=net0 \
  -device virtio-gpu-pci -display none -no-reboot -serial file:/tmp/android-boot.log &
```
Reminders:
- Remove stale `/tmp/android-boot.log` first; verify aliveness with `ps aux | grep qemu` + `ss -tlnp | grep 5555`, NOT pgrep -x.
- If `Could not set up host forwarding rule`: `fuser -k 5555/tcp` then retry.

## VERIFYING SUCCESS
```bash
adb connect 127.0.0.1:5555
adb devices                     # expect: 127.0.0.1:5555  device
adb shell getprop sys.boot_completed   # expect: 1
adb shell                       # console shell
```
- First boot needs a `console:/ $` prompt via serial log or adb after ~10-20 min real time (TCG slow).
- If only `offline`: wait longer / check `/tmp/android-boot.log` for adbd start.

## KNOWN REMAINING ISSUES (after vendor is fixed)
1. **GPU/EGL**: previously surfaceflinger/zygote crash-loop: "couldn't find an OpenGL ES implementation". Software libGLES_android.so exists. Try `adb shell setprop ro.hardware.egl swiftshader` (or goldfish) — note ro.* needs early boot or build.prop edit; alternatively set in ramdisk `/system/build.prop` or kernel cmdline. UI blocked but adb shell works.
2. **app_process32 missing** — 64-bit-only image; ignore (harmless).
3. **QEMU persistence**: background setsid/nohup instances LOOK dead via pgrep but port keeps listening — always verify with ps/port.
4. Zygote previously reached `ZygoteInit.preload` in past runs → core stack works; main past blocker was EGL.

## KEY FILES
| File | Purpose |
|---|---|
| `/home/ubuntu/android-qemu/kernel-ranchu` | guest kernel 4.4.302 |
| `/home/ubuntu/android-qemu/ramdisk6_fixed.img` | fixed ramdisk (fstab without check) |
| `/home/ubuntu/android-qemu/system.raw2` | correct system image (root = /system content) |
| `/home/ubuntu/android-qemu/vendor.raw` | vendor (currently 100MB; try enlarging to 1GB) |
| `/home/ubuntu/android-qemu/userdata.raw` | 2GB fresh ext4, mounts rw at /data |
| `/home/ubuntu/android-qemu/cache.raw` | 1GB fresh ext4 |
| `/tmp/virt_fstab_data.dtb` | **current DTB** (data node, no check) — keep |
| `/tmp/virt_fstab.dtb` | old DTB (userdata node + check) — superseded |
| `/tmp/virt_fstab_nochek.dtb` | intermediate (userdata node, no check) |
| `/tmp/label_images.py` | SELinux labeling script |
| `/tmp/ramdisk_extract/file_contexts` | SELinux contexts source |
| `/tmp/ramdisk6_extract/` | extracted fixed ramdisk (edit fstab.ranchu here, repack) |
| `/tmp/vcontent/` | saved vendor content (38MB) for rebuilding vendor.raw |
| `/tmp/virt_fstab_orig.dts`, `/tmp/ult_fix.dts` | DTB sources |

## RAMDISK REPACK RECIPE (if ramdisk needs more edits)
```bash
cd /tmp/ramdisk6_extract   # edit files here
find . | cpio -o -H newc | gzip -9 > /home/ubuntu/android-qemu/ramdisk6_fixed.img
```

## DTB REBUILD RECIPE (if fstab changes needed)
```bash
dtc -I dtb -O dts /tmp/virt_fstab_data.dtb -o /tmp/x.dts   # edit x.dts
dtc -I dts -O dtb -o /tmp/virt_fstab_data.dtb /tmp/x.dts
```

## Suggested immediate next actions for new chat
1. Recreate **vendor.raw at 1GB** (per above) and relaunch — highest-probability fix for the current blocker.
2. Confirm all 4 mounts in `/tmp/android-boot.log` (no "Reboot start").
3. `adb connect 127.0.0.1:5555` → `adb shell getprop sys.boot_completed` → target = 1.
4. After adb works: tackle EGL (swiftshader) if UI is needed.
5. Save a fresh `ANDROID-EMULATOR-HANDOFF` once boot completes.
