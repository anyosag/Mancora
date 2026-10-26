## Install

| Platform | Download | Notes |
| --- | --- | --- |
| macOS 14 or later (Apple silicon and Intel) | `Mancora-@VERSION@-macOS.dmg` | Open the disk image and drag Mancora to Applications. |
| Windows 10 (1809) or later, x64 | `Mancora-@VERSION@-Windows-x64-Setup.exe` | Installs for the current user, with no administrator rights needed. A portable `.zip` is also available. |
| Linux x86_64 (command line only) | `mancora-@VERSION@-linux-x86_64.tar.gz` | Unpack and run `./mancora`. |

**First launch on macOS:** Mancora isn't notarized by Apple yet, so macOS blocks it the first time.
1. Try to open Mancora once.
2. Go to **System Settings ▸ Privacy & Security** and click **Open Anyway** next to the Mancora message.

Alternatively, run `xattr -dr com.apple.quarantine /Applications/Mancora.app` in Terminal.

**First launch on Windows:** the installer isn't code-signed yet, so SmartScreen may warn about it. Click **More info ▸ Run anyway**.

`SHA256SUMS.txt` lists the checksum of every download.

Mancora is free software under the GNU General Public License, version 3 or later.
