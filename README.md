# Serial Number Reader

[![License: MIT](https://img.shields.io/badge/license-MIT-green)](LICENSE)

A native macOS app that identifies connected iPhones, iPads and Macs by serial number — **including devices that won’t boot** — and optionally looks them up in Jamf Pro or Jamf School. Built for handling devices with no readable printed serial.

![Serial Number Reader](docs/screenshot.png)

## Features

- **Live USB detection** of Apple devices in Normal, Recovery and DFU mode. Detection uses only IOKit (no `libimobiledevice`).
- **Normal mode** — reads the device UDID, model, OS version and device name (no pairing or trust needed) and resolves the device in Jamf.
- **Recovery mode** — reads the serial number and ECID directly from the USB descriptor; the model is resolved from the CPID/BDID pair.
- **DFU mode** — detects the device and shows the model-specific button sequence to reach Recovery. Current devices expose no identifiers over USB in DFU; with Apple Configurator installed, the model, ECID and UDID are filled in automatically, and the serial number follows from Jamf (iPhones and iPads as mobile devices, Macs as computers).
- **Restore and Revive** — for devices in DFU or Recovery mode, through Apple Configurator: **Restore** erases the device and installs the latest or a specific IPSW (checked against the model and Apple’s signing status before anything is erased; a device whose model is unknown can only get the latest version); **Revive** reinstalls the OS and keeps the content. One device at a time, with a progress banner and log; quitting during a restore asks first.
- **Jamf Pro and Jamf School lookup** by serial or UDID — Jamf Pro directly or through the **Jamf Platform API** — showing the device’s Jamf name, serial, UDID, model, OS version, managed state, assigned user and last inventory date, with an **editable asset tag** and a link to the record.
- **Several saved connections** — switch between them with the picker in the toolbar or the **Connection** menu.
- **Mode switching without button presses** — send a booted device into Recovery mode (and read its serial hands-free), boot a Recovery-mode device back to normal, or Restart / Enter DFU a USB-C device, even when it’s unresponsive.
- **Session export** — save every device from the session as CSV (**File → Export Session…**), or copy all serial numbers at once. **Clear Disconnected** (toolbar and File menu) and **Remove from List** (right-click) tidy the list.
- **Activity log** — **Window → Activity Log** (⇧⌘L) lists every sign-in, lookup, asset tag change, connection test and USB action, with an export for bug reports that masks serial numbers, UDIDs and ECIDs. It is kept in memory only.
- **Demo Mode** — try the app without a device or a Jamf tenant: a pretend iPhone and the sample Jamf servers “Contoso Jamf Pro (Demo)” and “Contoso Academy (Demo)”. Every action on the pretend iPhone is simulated; nothing is sent to a device or a tenant, and real devices are hidden while it’s on.
- **Copy buttons** and a scannable **QR code** for the serial number.

## Requirements

- macOS 14 or later.
- USB-C power actions (Restart / Enter DFU) require an Apple Silicon Mac host and a USB-C target device, and prompt for an administrator password. They work only while one device is connected, and nothing else may be connected to another USB-C port of the Mac (no second device, hub or USB-C charger; charging with MagSafe is fine): the command goes to a port, not to a device.
- Restore, Revive, Remove Trust and DFU identification require [Apple Configurator](https://apps.apple.com/app/apple-configurator/id1037126344) (free). Serial Number Reader uses its command-line tool; no setup is needed.

## Installation

Download the latest build from [Releases](../../releases), unzip, and move **Serial Number Reader.app** to your Applications folder. The app is signed with a Developer ID and notarized by Apple. **Settings → Updates** checks GitHub for new versions.

## Usage

Connect a device over USB. It appears in the sidebar with its mode; select it to see full details.

| Mode | What you get | Actions |
| --- | --- | --- |
| Normal | UDID, model, OS version, then Jamf record (serial, user, asset tag, …) | Enter Recovery · Restart · Enter DFU · Remove Trust |
| Recovery | Serial number + ECID read directly; model from CPID/BDID; Jamf record | Boot to Normal · Restore · Revive · Restart · Enter DFU |
| DFU | Model, ECID and UDID via Apple Configurator; Jamf record; steps to enter Recovery mode | Restore · Revive · Restart |

Enter Recovery, Boot to Normal, Restore and Revive need no administrator password; Restart and Enter DFU use USB-C power delivery and prompt for one. Before asking, the app checks that its own app on disk is the signed one that is running. Only one action runs at a time, and none while a Restore or Revive runs.

> **iOS 27 and later:** Enter Recovery only works from a Mac the device trusts. Unlock the device and tap **Trust** once, or enter Recovery mode with the buttons — the app shows the steps for the model. **Remove Trust** deletes the pairing again afterwards.

> **Note on booted devices:** an iPhone or iPad that hasn’t been unlocked since power-on doesn’t enumerate over USB (iOS USB restricted mode). Unlock it once, or put it into Recovery mode to read the serial.

### Jamf Pro and Jamf School

Open **Settings → Connections** and add a connection with **+**. **Test Connection** checks it. Each connection is one of:

- **Jamf Pro**, signing in with an **API client** or a **Username and password** — enter your Jamf Pro server URL and credentials. The account needs read access to mobile devices and computers (and update access to edit asset tags).
- **Jamf Platform API** — create an integration in [Jamf Account](https://account.jamf.com) scoped to a **platform environment**, with the `devices:read` permission (plus `devices:update` to edit asset tags). Enter its region, client ID, client secret and environment ID. The Jamf Pro URL is optional and only used for “Open in Jamf Pro” links. Integrations expire after six months.
- **Jamf School** — enter your Jamf School URL, Network ID and an API key (Organization → Settings → API) with read access to devices, plus write access to edit asset tags.

Secrets are stored in the macOS Keychain, never in preferences. Settings from versions before saved connections are converted once, automatically; the old settings are left as they were.

### Device model data

The CPID/BDID → model mapping lives in [`AppleDeviceModels.json`](Serial%20Number%20Reader/AppleDeviceModels.json) as a bundled resource, covering iPhone 8 and later, all iPads from 2017 onward, and Apple Silicon Macs. It can be updated without code changes.

### Network use

Besides Jamf Pro or Jamf School, the app contacts GitHub (update check, can be turned off) and, when preparing a Restore, the public [ipsw.me](https://ipsw.me) data to show the latest signed version and check an IPSW’s signing status — only the model identifier and build number are sent.

## Building from source

Open `Serial Number Reader.xcodeproj` in Xcode and build the **Serial Number Reader** scheme. The only dependency is [JTKit](https://github.com/JordyThery/JTKit), the shared package of these apps, which Xcode fetches itself. Unit tests (Swift Testing) cover the USB descriptor parser, UDID and ECID handling, Configurator output parsing, IPSW checks, usbmuxd and lockdown framing, the pairing checks of the trusted connection, the safeguards of the power actions, connection conversion, the Jamf networking (on a fake server), the CSV export, the activity log entries, Demo Mode and the acknowledgement.

The app runs outside the App Sandbox: it needs direct IOKit access for USB enumeration, and the USB-C power actions use the private `AppleHPM` port-controller interface, which requires root (the app re-launches itself with administrator privileges for those actions only).

## Architecture

- `USBDeviceMonitor` — wraps IOKit USB arrival/removal notifications and publishes an observable device list; the UI consumes only this.
- `DescriptorParser` — pure, unit-tested parsing of the Recovery/DFU USB serial descriptor and UDID normalization.
- `ModelDatabase` — loads the bundled CPID/BDID model map.
- `USBHardware` / `DemoUSB` — the one doorway to real devices (lockdown, iBoot, the power actions, `cfgutil`), and Demo Mode’s pretend iPhone, which never reaches it.
- `JamfClient` / `JamfStore` — the app’s Jamf lookups and asset-tag updates on JTKit’s Jamf Pro (direct or through the Platform API gateway) and Jamf School clients, and their UI-facing state.
- `JamfConnection` / `LegacySettingsConversion` — the saved connections, and the one-time conversion of older settings.
- `Usbmux` / `LockdownTLS` — minimal usbmuxd/lockdown client: unpaired device details, and Enter Recovery — unpaired, or over a trusted (paired) TLS session where iOS requires it.
- `Configurator` / `RestoreController` — runs Apple Configurator’s `cfgutil` to identify devices, Restore, Revive and remove trust, and tracks a running Restore or Revive.
- `SessionExport` — CSV export and serial list built from the session’s device list.
- `VDMTool` / `DeviceActionController` — USB-PD vendor-defined-message power actions via `AppleHPM`, and the other device actions.
- `AboutInfo` — the About window and the acknowledgement.

## Credits

USB-PD VDM power actions are derived from [AsahiLinux/macvdmtool](https://github.com/AsahiLinux/macvdmtool) and [osy/ThunderboltPatcher](https://github.com/osy/ThunderboltPatcher) (Apache-2.0); attribution is retained in the relevant source files. The full license is in [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md) and in the app’s About window.

## Support

If Serial Number Reader saves you time, you can [buy me a coffee](https://buymeacoffee.com/jordythery). ☕️

## License

[MIT](LICENSE)
