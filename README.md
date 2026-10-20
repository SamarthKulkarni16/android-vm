# android-vm
On-demand KVM-accelerated Android emulator (GitHub Actions), live-controlled with adb + scrcpy.

**Normal use:** double-click the *Android Live* icon on the VM desktop (launcher/android-live-launcher.sh).
- It starts the cloud phone (or reuses a running one) and opens the phone window.
- Your apps, logins and files are restored from the last session and saved again when the session ends.
- The session ends at the **5 hour limit** or when you close the phone window (**X**), whichever comes first; it then saves cleanly (4-8 min) and shuts down.
- A new session waits automatically if the previous one is still saving.

**Privacy:** this repo is public, so the saved phone (release `avd-state`) is AES-256 encrypted. The key is the Actions secret `AVD_STATE_KEY` (if it is not set, a key derived from `ADB_PRIVATE_KEY` is used). Never upload the phone state unencrypted.

**Files:** `avd-lib.sh` (save/restore, generations, integrity check), `restore-avd.sh`, `tunnel-and-serve.sh` (tunnel, keep-alive, stop request, clean save), `logs/session-state.txt` (booting/running/saving/ended), `logs/stop-request.txt` (written by the launcher).
