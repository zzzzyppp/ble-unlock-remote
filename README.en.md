# BLE Unlock

**Tap your phone to unlock your Mac.** No reaching for Touch ID, no typing a password.

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform: macOS 11+](https://img.shields.io/badge/macOS-11%2B-black.svg)](#requirements)
[![Platform: Android 8+](https://img.shields.io/badge/Android-8.0%2B-3DDC84.svg)](#requirements)
[![Release](https://img.shields.io/github/v/release/zzzzyppp/ble-unlock-remote)](https://github.com/zzzzyppp/ble-unlock-remote/releases/latest)

[中文文档](README.md) · **English**

Your phone sends an **HMAC-SHA256 signed** command to the Mac over Bluetooth Low
Energy. Once verified, the Mac types your login password for you. One phone can
hold the credentials for several Macs and switch between them.

![BLE Unlock demo](docs/demo-en.gif)

---

## Features

- **One-tap unlock** — tap once on your phone, the Mac unlocks
- **Multiple passwords per Mac** — tried in order, handy right after a password change
- **Choose which password to use** — the *Fill Password* button fills on tap, changes on long-press
- **Works while your phone is locked** — a foreground service keeps the BLE link alive
- **Multiple Macs** — each with its own token, switchable in the app
- **Drag-and-drop install** — drop the app into Applications. No terminal, no Xcode
- **Passwords never leave the Mac** — stored in the macOS Keychain, never sent over
  Bluetooth, never written to a config file. The phone does not even store the
  password text — only *which slot* to use
- **Signed commands** — HMAC-SHA256 authentication, nonce anti-replay, timestamp check
- **No Gradle, no third-party libraries** — the APK is built directly with
  aapt2/javac/d8/apksigner

---

## Download

**Get it from [Releases](https://github.com/zzzzyppp/ble-unlock-remote/releases/latest):**

| File | For | Notes |
|---|---|---|
| `BLEUnlock-*.dmg` | **Recommended** | Drag to Applications, then configure inside the app. **No terminal, no Xcode.** Apple Silicon only |
| `mac-ble-unlock.sh` | Intel Macs / CLI users | Self-contained script. Needs Xcode Command Line Tools; compiles locally |
| `BLEUnlockRemote.apk` | Android | Signed, ready to sideload |
| `SHA256SUMS.txt` | — | Checksums |

Verify your download:

```bash
shasum -a 256 -c SHA256SUMS.txt
```

---

## Quick Start

### 1. Mac

#### Option A: drag-and-drop (recommended)

1. Open the DMG
2. Drag **BLE Unlock** onto the **Applications** folder
3. Open **BLE Unlock** from Applications
4. **Right-click the app → Open → then click Open again**

   > You only need to do this once. This project has no Apple Developer
   > certificate and therefore cannot be notarized.

5. Enter your login password when prompted; everything else is automatic
6. Follow the prompts to grant **Accessibility** permission and note your **pairing token**

> Run it from Applications, not from inside the DMG. The DMG is read-only and
> macOS assigns it a random path each time, which prevents permissions from sticking.

Running the app again later reconfigures/updates it. **Your pairing key is preserved**,
so nothing on the phone needs to change.

#### Option B: command-line script

For Intel Macs, or if you prefer a terminal. First install the compiler:

```bash
xcode-select --install
```

Then:

```bash
chmod +x mac-ble-unlock.sh
./mac-ble-unlock.sh install
```

### 2. Phone

1. Install `BLEUnlockRemote.apk` (allow installing from unknown sources)
2. Open the app and grant Bluetooth permission (Android 12+ asks for "Nearby devices")
3. Tap **＋ Add Mac**, give it a name, and paste the **pairing token**
4. Tap the big **UNLOCK** button

The app uses a foreground service, so **you can unlock your Mac while your phone is locked**.

There are three buttons:

| Button | What it does |
|---|---|
| **UNLOCK** | Normal unlock. The Mac first checks whether the screen is locked, then tries each password in order |
| **Fill: [current]** | **Tap** to fill the selected password immediately, **skipping the lock-screen check**. **Long-press 2 s** to choose a different password |
| Reconnect / Lock Mac | Reconnect, or lock the Mac on demand |

> *Fill* is an explicit manual command: it types what you chose right away, without
> checking the screen state and without falling back to other passwords. *Unlock*
> confirms the screen is locked first and will keep trying your other passwords.

### 3. Multiple Macs

Install on each Mac separately — each gets its own token. Add them all in the app
and switch with **Switch Mac**; `●` marks the active one. Only one Mac is connected
at a time.

---

## Multiple Passwords

Each Mac can store several login passwords. Unlocking tries them **from top to bottom**
until the screen unlocks.

**Why:** right after changing your login password, keep both the old and the new one
here so you can never lock yourself out. Also useful when one Mac has several accounts.

### Choosing which password on the phone

The phone has a **Fill Password** button for picking which slot to use. **The first
password is the default.**

- The phone does **not** store password text — passwords live only in the Mac Keychain.
  The phone records the *slot number* and a name you give it (e.g. "Current", "Old")
- **Tap** to fill with the current selection; **long-press** to pick another slot or
  rename the slots
- The normal **UNLOCK** button includes the slot number, and the Mac tries it **first**.
  If it is wrong the Mac automatically falls back through the remaining passwords,
  so a stale selection never locks you out
- **Fill** skips the lock-screen check entirely and tries **only** the selected
  password — what you picked is what gets typed

> Slots are positional. If you add, remove, or reorder passwords on the Mac, the slot
> the phone points at may now hold a different password. Re-check it when you change them.

### Managing passwords on the Mac

- **GUI:** open the app and click **Manage Passwords (multiple allowed)**
- **CLI:**

```bash
SVC=~/Library/Application\ Support/BLEUnlockCmd/BLEUnlockCmd.app/Contents/MacOS/BLEUnlockCmd

"$SVC" --passwords list              # show (masked)
"$SVC" --passwords list --json       # counts and lengths only
printf 'pw\n' | "$SVC" --passwords add        # append one
printf 'a\nb\n\n' | "$SVC" --passwords set   # replace all (blank line ends)
"$SVC" --passwords remove --index 2  # remove the 2nd
"$SVC" --passwords clear             # remove all
```

**Implementation notes:**

- All passwords live in a **single Keychain item** (a JSON array). Nothing is written to disk
- Order is the try order. After typing a password the Mac waits ~1.2 s to see whether the
  screen unlocked, and only then moves on
- Before trying the next password it sends an **Esc** to clear the field, so leftovers from
  the previous attempt cannot be mixed in
- **Backwards compatible:** if the Keychain holds a single plaintext password (how earlier
  versions stored it), it is treated as one password
- **Passwords cannot contain newlines** — input is read line by line, so a newline would
  split one password into two. The app rejects it explicitly rather than corrupting it
- Non-ASCII passwords (Chinese, accented letters) are stored by the Keychain in NFD form;
  the app normalizes to NFC so storage and comparison stay consistent

---

## The Two Permissions You Must Grant

| Permission | Where | If you don't |
|---|---|---|
| Accessibility | System Settings → Privacy & Security → Accessibility | The Mac cannot type the password, and unlocking fails silently |
| Bluetooth | Prompted on first run | The Mac cannot advertise and the phone cannot find it |

> If the Keychain asks for access, choose **Always Allow** — nobody can click a dialog
> while the screen is locked.

### Which file to authorize

The Accessibility grant must go to the **background service**, not to the setup app:

```
~/Library/Application Support/BLEUnlockCmd/BLEUnlockCmd.app/Contents/MacOS/BLEUnlockCmd
```

Granting it to **BLE Unlock** in Applications (that is the setup app) has no effect.

If `BLEUnlockCmd` is already listed and toggled on but still doesn't work, **remove it
with − and add it again** — the old grant may be bound to a previous binary.

Check the real state at any time:

```bash
cat ~/Library/Application\ Support/BLEUnlockCmd/daemon-status.json
# "axTrusted" : true   means the actual daemon has permission
```

> Note: querying permission from a terminal can be misleading — TCC trust is **inherited
> from the parent process**, so a child of a trusted terminal reports "granted" even when
> the launchd-started daemon does not have it. The file above is written by the daemon
> itself and is the authoritative answer.

---

## How It Works

The unlock mechanism is the same as [BLEUnlock](https://github.com/ts1/BLEUnlock):
read the login password from the Keychain and synthesize keyboard input with `CGEvent`.

```
┌──────────────┐                      ┌────────────────────────────┐
│  Android app │                      │  Mac (BLE peripheral / GATT)│
│              │  1. scan for service │                            │
│  BLE central │ ───────────────────► │  CBPeripheralManager       │
│              │  2. write 62-byte cmd│                            │
│              │ ───────────────────► │  verify HMAC-SHA256        │
│              │                      │  check timestamp + nonce   │
│              │  3. subscribe status │                            │
│              │ ◄─────────────────── │  reply "OK" / "ERR_*"      │
└──────────────┘                      │            │               │
                                      │            ▼               │
                                      │  wake display → confirm    │
                                      │  lock → read Keychain →    │
                                      │  CGEvent types pw + Return │
                                      └────────────────────────────┘
```

### Packet format (62 bytes)

| Offset | Len | Contents |
|---|---|---|
| 0 | 2 | magic `"BU"` (0x42 0x55) |
| 2 | 1 | protocol version `0x01` |
| 3 | 1 | command: `0x01` unlock / `0x02` lock / `0x03` ping / `0x04` unlock-with-slot |
| 4 | 8 | Unix timestamp, big-endian UInt64 (seconds) |
| 12 | 16 | random nonce |
| 28 | 1 | password slot (0-based). Only for `0x04`; covered by the HMAC |
| 29 | 1 | skip-lock-check flag (0/1). Only for `0x04`; covered by the HMAC |
| 30 | 32 | `HMAC-SHA256(first 30 bytes)` |

Service `B1E0A100-0001-4A00-8000-00805F9B0001`; command characteristic `...-0002-...`;
status `...-0003-...`; info `...-0004-...`.

> Bytes 28–29 were reserved. When no slot is given and the lock check is not skipped,
> they stay 0 and the command stays `0x01`, so **older Mac services keep working**.
> Both fields are inside the HMAC coverage, so a man-in-the-middle cannot change which
> password is used.

### Security design

- **Authentication:** HMAC-SHA256 with a 32-byte pre-shared key. Without the token an
  attacker cannot forge a command or recover the key from sniffed traffic
- **Anti-replay:** 16-byte random nonce with a 5-minute dedup cache; timestamps more
  than ±120 s off are rejected
- **Constant-time** HMAC comparison to avoid timing side channels
- **Passwords stay local:** in the macOS Keychain, never sent over Bluetooth, never
  written to a config file

---

## ⚠️ Security Notes

### 1. Do not redistribute your own build

The phone app contains the algorithm that derives the key from `mac-ble-unlock.sh`.
**Anyone holding both your built script and the APK can derive your pairing key** and
forge unlock commands.

- The official files in this repository **contain nobody's key** — the key is generated
  locally on each Mac during setup
- But if you ship this to others as a product, you are handing them unlock capability

Treat the two files like a password. This is intended as a **personal tool**.

### 2. What it does not protect against

- **An attacker with physical access to your Mac** — this project relies on macOS
  Accessibility and the Keychain and does not change those trust boundaries
- **BLE sniffers** — they can see that an unlock command was sent, but cannot forge or
  replay one (authenticity comes from the HMAC; the link itself is unencrypted)

### 3. Known limitations

- **Password login only.** Touch ID / Apple Watch cannot be synthesized
- The service prevents **idle system sleep** so Bluetooth advertising is not interrupted
  (the display still sleeps and locks normally)
- Once the Mac actually sleeps, BLE advertising stops and the phone cannot wake it
- The installer is **Apple Silicon only** (see Requirements)

---

## Requirements

| | |
|---|---|
| macOS | 11 or later |
| CPU | **Apple Silicon** for the drag-and-drop app; Intel Macs use the CLI script |
| Android | 8.0 or later (minSdk 26, targetSdk 34) |
| Swift | Xcode Command Line Tools — only needed for Option B |

> **Why is the installer Apple Silicon only?**
> It is built in an environment with only Command Line Tools (no full Xcode), whose Swift
> compatibility libraries are arm64-only (`libswiftCompatibility56.a` is arm64/arm64e),
> so x86_64 cannot be cross-compiled. Intel Macs should use the CLI script, which compiles
> natively on the machine.

---

## Verified / Not Verified

### Verified

| Item | Method | Result |
|---|---|---|
| Cross-language protocol | Java and Swift HMAC compared byte-for-byte on identical inputs | Identical |
| HMAC correctness | RFC 4231 test vector + independent Python implementation | Pass |
| Packet validation | Tampered HMAC / wrong key / bad magic / short packet / stale timestamp | All correctly rejected |
| Anti-replay | Same nonce sent twice | Correctly rejected (`ERR_REPLAY`) |
| Password slot encoding | 7 combinations of slot × skip-check, both languages | Consistent |
| Slot inside HMAC | Flipping byte 28 | Invalidates the HMAC |
| Token parsing | base64 / URL-safe / hex / separators / invalid input | As expected |
| Multi-password storage | Round-trip, special characters, non-ASCII, ordering, empty list | Pass |
| Password safety | Empty and newline-containing lists | Correctly rejected, data intact |
| Upgrade path | Re-install over an existing setup | Pairing key preserved |
| Real end-to-end | Phone → BLE → Mac → typed password → unlocked | Success (`解锁结果: OK` in the log) |
| Localization | Both language bundles resolved in the built app | Pass |

Reproduce:

```bash
./verify-protocol.sh       # cross-language protocol consistency
./verify-multikey.sh       # token parsing / multi-key storage / migration
./build/e2e/BLEUnlockCmd --selftest-protocol   # protocol + unlock flow self-test
```

### Not verified

- **UI interactions** — switching/renaming/deleting Macs, tapping and long-pressing
  *Fill Password*, naming slots. The logic and protocol layers are verified; the button
  behaviour needs a run on a real device
- **Trying several passwords for real** — storage, reading, ordering and reordering are
  verified; the full locked-screen sequence ("try the wrong one, then the right one")
  needs confirmation on a real Mac
- **Compatibility after a major macOS upgrade** — locking uses the private
  `login.framework` API (with a screensaver fallback); re-verify after a major upgrade

> Suggested check: save two passwords on the Mac with the first one deliberately wrong,
> lock the screen, and tap **UNLOCK**. The log should show it trying the wrong one,
> moving on after ~1.2 s, then succeeding with the right one.

---

## Troubleshooting

### The app is stuck on "Scanning"

1. Make sure the Mac service is running: `./mac-ble-unlock.sh status`
2. Make sure Bluetooth is on, on the Mac (System Settings → Bluetooth)
3. Check the log for `广播失败` ("advertising failed")
4. Tap **Reconnect**, or restart the service and retry
5. Android battery optimisation can kill the background service — set
   Settings → Apps → BLE Unlock → Battery → **Unrestricted**

### "Command delivered" but the Mac does not unlock

Most likely first:

1. **Missing Accessibility permission** — see the section above, and make sure you
   authorized the *service*, not the setup app
2. **No password in the Keychain** — re-run setup, or use `--passwords list`
3. **The Mac screen was not actually locked** — returns `NOT_LOCKED`, which is normal
4. **Token mismatch** — returns `ERR_HMAC`
5. **Phone and Mac clocks differ too much** — returns `ERR_TIME`; sync the phone's time
6. Check the log: `tail -20 ~/Library/Application\ Support/BLEUnlockCmd/ble-unlock.log`

### Password verification fails

After changing your login password, re-run the app to save the new one.
You can keep the old one too — see [Multiple Passwords](#multiple-passwords).

---

## Building From Source

```bash
# Mac service (after editing mac-src/main.swift)
./build-mac.sh          # regenerates the self-contained mac-ble-unlock.sh

# Android (after editing android-src/)
export ANDROID_SDK_ROOT="$PWD/toolchain/android-sdk"
./build.sh              # produces dist/BLEUnlockRemote.apk

# Drag-and-drop installer (.dmg)
./build-installer.sh
```

`build.sh` does not use Gradle: it calls aapt2 / javac / d8 / apksigner directly and
builds offline. It needs JDK 17+ and an Android SDK with `platforms/android-34` and
`build-tools` 34 or newer.

> Known issue: d8 from build-tools **34.0.0** crashes internally (an R8 NPE) on this
> project's code, so `build.sh` prefers 35.0.0 or newer.

### Localization

The Mac app and the Android app ship **one bilingual build** that follows the system
language (English or Simplified Chinese).

```bash
python3 tools/localize-mac.py      # regenerate Mac .strings and rewrap sources
python3 tools/localize-android.py  # regenerate Android strings.xml files
```

The Mac strings live in `installer-src/strings/{en,zh-Hans}.lproj/`; the Chinese text is
the key, so a missing translation falls back to Chinese rather than showing a bare key.
Android uses `res/values/` (Chinese, default) and `res/values-en/`.

Diagnostic logs (`--check`, `--diag`, the service log) are currently Chinese only.

### Signing key

The APK signing key is **not** in the repository. `build.sh` looks for it in:

1. `$BLEUNLOCK_KEYSTORE_DIR`
2. `~/.config/ble-unlock/` ← default
3. the project directory (legacy)

If none exists it creates one and tightens permissions (dir 700 / file 600).
**Without the key you cannot upgrade an installed APK** — back it up.

---

## Repository Layout

```
├── dist/BLEUnlockRemote.apk        ← Android package
├── mac-ble-unlock.sh               ← Mac CLI installer (self-contained, for Intel Macs)
├── mac-src/main.swift              ← Mac service source
├── template.sh                     ← template for the script above
├── build-mac.sh                    ← regenerates the self-contained script
├── android-src/                    ← Android source
│   ├── AndroidManifest.xml
│   ├── java/com/bleunlock/remote/
│   │   ├── Protocol.java           ← protocol and token parsing
│   │   ├── MacEntryStore.java      ← multi-Mac credential storage
│   │   ├── BleService.java         ← foreground service keeping the BLE link
│   │   └── MainActivity.java       ← UI
│   └── res/                        ← strings (values = zh, values-en = en)
├── build.sh                        ← builds the APK
├── build-installer.sh              ← builds the drag-and-drop installer (.dmg)
├── installer-src/                  ← setup app source
│   ├── app/                        ← the app itself
│   │   ├── main.swift              ← entry point (explicit NSApplication)
│   │   ├── AppDelegate.swift       ← flow orchestration
│   │   ├── SetupWindow.swift       ← setup wizard UI
│   │   ├── PasswordEditor.swift    ← multi-password manager
│   │   ├── Localization.swift      ← L() helper
│   │   ├── Installer.swift         ← installation logic
│   │   └── BuildInfo.swift         ← version info (generated at build time)
│   ├── strings/                    ← en.lproj / zh-Hans.lproj
│   └── test/                       ← end-to-end tests for the install logic
├── verify-protocol.sh              ← cross-language protocol verification
├── verify-multikey.sh              ← token / storage / migration verification
└── tools/
    ├── VerifyProtocol.java         ← protocol verification tool
    ├── VerifyMultiKey.java         ← multi-key verification tool
    ├── testdoubles/                ← real stand-ins for android.jar stubs (tests only)
    ├── ble-test-client.swift       ← test client acting as the phone
    ├── localize-mac.py             ← regenerates Mac localization
    ├── localize-android.py         ← regenerates Android localization
    └── make_icons.py               ← generates the launcher icon
```

### Inside the installer

The service is packaged as a **nested app** inside the setup app, not as a loose binary:

```
BLE Unlock.app                          ← drag into Applications
└── Contents/
    ├── MacOS/BLEUnlockSetup            ← setup wizard
    └── Resources/
        └── BLEUnlockCmd.app            ← the service (copied out at install time)
            └── Contents/
                ├── Info.plist          ← includes the Bluetooth usage description
                ├── PkgInfo
                ├── MacOS/BLEUnlockCmd  ← the daemon that actually unlocks
                └── Resources/capabilities
```

Code signing goes from the inside out: the nested service first, then the outer app.
Installation copies with `ditto` so nested signatures and extended attributes survive.

---

## Changelog

### Unreleased (local build)

- **Bilingual** — the Mac app and Android app now follow the system language
  (English / Simplified Chinese)
- **Fill Password button** — tap to fill and skip the lock-screen check; long-press to change
- **Choose a password on the phone** — pick which slot to use, default is the first
- **Multiple passwords per Mac** — tried in order
- **Nested service packaging** — `BLEUnlockCmd.app` with a full Info.plist

### v1.3.1

- Fixed "phone reports missing Accessibility permission". Root cause: TCC trust is
  **inherited from the parent process**, so the setup app's child process falsely
  reported "granted" while the launchd-started daemon actually lacked it. The daemon
  now reports its own state

### v1.3.0

- Installation changed to **drag into Applications**, configured inside the app

### v1.2.1

- Fixed the installer opening with no window (`@main` does not drive AppKit correctly
  when only Command Line Tools are installed)

### v1.1.0

- The phone can store credentials for multiple Macs and switch between them

See [Releases](https://github.com/zzzzyppp/ble-unlock-remote/releases) for the full history.

---

## Acknowledgements

The unlock mechanism (reading the Keychain password + synthesizing keyboard input with
`CGEvent` + locking via `login.framework`) was inspired by Takeshi Sone's
[BLEUnlock](https://github.com/ts1/BLEUnlock) (MIT).

This project is an **independent implementation** and does not copy its source. The BLE
GATT protocol, pairing authentication (HMAC-SHA256) and anti-replay design are original
to this project.

---

## License

[MIT](LICENSE)
