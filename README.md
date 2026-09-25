# KVM Auto Display Switch

When you press your USB KVM switch, your keyboard and mouse move to the other computer, but the monitor stays on the old input. This project closes that gap: a small menu-bar app on the Mac and a small tray app on Windows switch the monitor's input over DDC/CI (VCP `0x60`) whenever the KVM moves.

It does one thing. There are no brightness or color controls, no accounts, no telemetry, and no third-party display software (BetterDisplay, Lunar, MonitorControl or ControlMyMonitor are not needed).

## How it works

Many monitors only listen to DDC/CI commands on the input they are currently showing. A computer can switch the monitor away from itself, but it cannot pull the monitor back. So each computer switches the monitor to the other one at the moment the KVM leaves it:

```
Press KVM -> USB devices leave the Mac -> Mac app sends 0x60 = PC input  -> monitor shows the PC
Press KVM -> USB devices leave the PC  -> PC app sends 0x60 = Mac input  -> monitor shows the Mac
```

Each app detects the KVM by watching for the KVM's own USB hub disappearing, matched by vendor and product ID. A switch counts as verified when the monitor stops answering DDC on the sending computer, because that proves it left that computer's input.

## Download

Every merge to `main` publishes a release with both apps: [Releases](../../releases/latest).

- `KVM-Switcher-macOS-<version>.zip` contains `KVM Switcher.app`, the `kvmctl` command-line tool, and the helper scripts. It requires macOS 13 or later on Apple Silicon.
- `KVM-Switcher-Windows-<version>.zip` contains `KVMSwitcher.exe` (28 KB, no runtime or installer needed) and `find-inputs.ps1`. It requires 64-bit Windows 10 or 11.

Both apps are unsigned. On the Mac, move the app to `Applications` and clear the download quarantine once, from the unzipped folder:

```bash
xattr -dr com.apple.quarantine "/Applications/KVM Switcher.app" kvmctl *.sh
```

On Windows, SmartScreen warns on first launch. Click "More info", then "Run anyway".

## Setup

You need three values: the input value for each computer, and the KVM's USB IDs. Monitors often ignore the input values they advertise, so measure them instead of trusting the spec sheet.

### 1. Find each computer's input value

On the Mac, with the other computer awake and connected, run:

```bash
./find-inputs.sh               # from the release zip
macos/scripts/find-inputs.sh   # from a source checkout
```

It sends one candidate value at a time (`0x01` to `0x12`, and `0x1B`) and waits for Enter. Watch the monitor. When it switches to the other computer, write that value down. Most monitors then ignore the Mac until you bring them back with the monitor's own buttons, so do that before pressing Enter again.

To find the Mac's input value, run the same sweep from Windows while the monitor shows the PC:

```powershell
powershell -ExecutionPolicy Bypass -File find-inputs.ps1
```

On the reference monitor, a 34D901 with an MStar scaler, the monitor advertised `0x11`, `0x12`, `0x0F` and `0x10` and ignored all of them. The values that worked were `0x06` for the Mac's HDMI input and `0x08` for the PC's DisplayPort input.

### 2. Find the KVM's USB IDs

On the Mac, run `find-kvm-usb.sh`, press the KVM button a few times, then press Ctrl+C. The devices that disappear and reappear together belong to the KVM. Use the hub entries, since they are the KVM itself:

```
11:31:21 REMOVED USB2.1 Hub vendorId=13782 productId=9488
11:31:21 REMOVED USB3.2 Hub vendorId=13782 productId=13584
```

Windows uses the same IDs in hexadecimal: `13782` is `35D6`, `9488` is `2510`, and `13584` is `3510`. You can confirm them in Device Manager under a hub's Properties, Details tab, Hardware Ids (for example `USB\VID_35D6&PID_2510`).

### 3. Configure the Mac

Open the menu-bar app and choose Settings, or edit `~/Library/Application Support/KVMSwitcher/config.json` directly. `kvmctl config init` writes a starter file with your monitor's ID.

```json
{
  "thisComputer": "mac",
  "monitors": [
    {
      "id": "3103FFFF-0000-0000-101F-010380502178",
      "name": "34D901",
      "inputs": { "HDMI-1": "0x06", "DP-1": "0x08" },
      "computers": { "mac": "HDMI-1", "windows": "DP-1" },
      "quirks": { "ddcOnlyOnActiveInput": true, "inputReadbackUnreliable": true }
    }
  ],
  "kvm": {
    "usbDevices": [
      { "vendorId": 13782, "productId": 9488 },
      { "vendorId": 13782, "productId": 13584 }
    ],
    "presentMeans": "mac",
    "absentMeans": "windows"
  }
}
```

| Field | Meaning |
| --- | --- |
| `id` | The monitor's EDID UUID from `kvmctl monitor list`. Leave it out to match by `name` instead. |
| `inputs` | Your names for the inputs, mapped to the values found in step 1. |
| `computers` | Which input belongs to which computer. |
| `quirks.ddcOnlyOnActiveInput` | Set it to `true` when the monitor ignores DDC from inputs it is not showing (step 1 tells you). It enables the "DDC went silent" verification. |
| `quirks.inputReadbackUnreliable` | Set it to `true` when `kvmctl monitor input get` reports nonsense values. |
| `kvm.usbDevices` | The IDs from step 2. `productId` is optional. |
| `kvm.presentMeans` / `absentMeans` | Which computer the KVM points to when the devices are present or gone. |

### 4. Configure Windows

Put `KVMSwitcher.exe` in a folder you can write to, such as `%LOCALAPPDATA%\KVMSwitcher\`. On first launch it writes `kvm-switcher.ini` next to itself:

```ini
[monitor]
target=0x06        ; the Mac's input value from step 1
[kvm]
vid=35D6           ; the KVM's USB vendor ID, hexadecimal
pids=2510,3510     ; optional product IDs, hexadecimal
[app]
auto=0             ; the tray menu's Auto switch toggle writes this
```

Edit it from the tray menu (Settings), then quit and restart the app.

### 5. Turn it on

- **Mac:** click the menu-bar item (it shows `● HDMI` when the monitor is on the Mac, `○ away` otherwise). Turn on Auto switch and Launch at Login.
- **Windows:** click the tray icon. Turn on Auto switch and Launch at login.

## Testing manually

On the Mac, the check script prints what the app sees without sending anything to the monitor: the monitor, DDC status, capabilities, current input, the config, and the KVM state.

```bash
./check.sh                  # release zip
macos/scripts/check.sh      # source checkout
```

Then switch by hand, one direction at a time:

| Step | Command or action | Expected result |
| --- | --- | --- |
| Mac to PC | `kvmctl monitor input set windows` | The monitor shows the PC, and the command prints `success (monitor left this computer's input ...)` |
| PC to Mac | Tray menu on Windows, "Send monitor to other computer" | The monitor shows the Mac. `kvm-switcher.log` ends with `verified: monitor left this PC's input` |
| KVM detection on the Mac | `kvmctl kvm watch`, then press the KVM | `KVM -> windows`, then `KVM -> mac` |
| Everything together | `kvmctl kvm watch --auto`, then press the KVM | The monitor follows the KVM to the PC. Coming back needs the Windows app. |

Other `kvmctl` commands: `monitor list`, `monitor caps`, `monitor input list`, `monitor input get`, `monitor input send <value>` (a single raw write with no verification), and `config path`. Add `-v` to see raw I2C bytes. Both apps keep a log: `~/Library/Logs/KVMSwitcher.log` on the Mac, and `kvm-switcher.log` next to the exe on Windows.

## Known limitations

- The Mac app works on Apple Silicon only. It uses the private `IOAVService` API, the same one MonitorControl and m1ddc use, so a macOS update could break it.
- DDC/CI must be enabled in the monitor's on-screen menu.
- DisplayLink adapters and many docks do not pass DDC through. Direct USB-C to DisplayPort or HDMI cables work best. The built-in HDMI port worked on an M5 MacBook Pro, but some M1 and M2 models are reported not to support DDC on it.
- The Windows app sends the command to every monitor attached to the PC.
- Some monitors silently drop DDC writes. Both apps retry up to three times and log a failure if the monitor never leaves the input.

## Building from source

The Mac side needs Xcode or the Command Line Tools (Swift 5.10 or later):

```bash
cd macos
swift test
scripts/install-app.sh      # builds, installs to ~/Applications and launches
```

The Windows side is cross-compiled from macOS or Linux with mingw-w64:

```bash
brew install mingw-w64      # or: apt-get install gcc-mingw-w64-x86-64
windows/build.sh
```

## Releases

`.github/workflows/release.yml` runs on every push to `main`. It runs the tests, builds both apps, bumps the patch version (`v0.1.0`, `v0.1.1`, and so on), and publishes a GitHub release. The release notes list the commit subjects since the previous release, plus a compare link. To start a new minor or major series, push a tag such as `v0.2.0` by hand, and the next merge continues from there.

## Repository layout

```
macos/
  Sources/KVMCore/      platform-free logic: DDC framing, capabilities, config, switching, KVM state
  Sources/MacDDC/       macOS DDC backend (IOAVService) and USB watcher (IOKit)
  Sources/kvmctl/       command-line tool
  Sources/KVMMenuBar/   menu-bar app
  Tests/                unit tests, including a simulated monitor with the quirks above
  scripts/              check, find-inputs, find-kvm-usb, bundle-app, install-app
windows/
  kvm_switcher.c        the whole Windows tray app
  build.sh              cross-compile script
  find-inputs.ps1       input value finder
```
