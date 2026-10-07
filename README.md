# Serial Number Reader

A native macOS app that identifies connected iPhones, iPads and Macs by serial number — **including devices that won't boot** — and optionally looks them up in Jamf Pro. Built for handling devices with no readable printed serial.

## Features

- **Live USB detection** of Apple devices in Normal, Recovery and DFU mode, using IOKit (no private device frameworks, no `libimobiledevice`).
- **Normal mode** — reads the device UDID (no pairing or trust prompt) and resolves it in Jamf Pro.
- **Recovery mode** — reads the serial number and ECID directly from the USB descriptor; model is resolved from the CPID/BDID pair.
- **DFU mode** — detects the device and shows the model-specific button sequence to reach Recovery (current devices expose no identifiers over USB in DFU).
- **Jamf Pro lookup** by serial or UDID, showing device name, serial, UDID, model, OS version, managed state, assigned user and last inventory date — with an **editable asset tag** and a link to the record.
- **USB-C power actions** — Restart or Enter DFU over any port, even on an unresponsive device.
- **Copy buttons** and a scannable **QR code** for the serial number.

## Requirements

- macOS 14 or later.
- USB-C power actions (Restart / Enter DFU) require an Apple Silicon Mac host and a USB-C target device, and prompt for an administrator password.

## Installation

Download the latest build from [Releases](../../releases), unzip, and move **Serial Number Reader.app** to your Applications folder. The app is signed with a Developer ID and notarized by Apple.

## Usage

Connect a device over USB. It appears in the sidebar with its mode; select it to see full details.

| Mode | What you get |
| --- | --- |
| Normal | UDID, then Jamf record (serial, model, user, asset tag, …) |
| Recovery | Serial number + ECID read directly; model from CPID/BDID; Jamf record |
| DFU | Presence detection and guided steps to enter Recovery mode |

> **Note on booted devices:** an iPhone or iPad that has not been unlocked since power-on does not enumerate over USB (iOS USB restricted mode). Unlock it once, or put it into Recovery mode to read the serial.

### Jamf Pro

Open **Settings** and enter your Jamf Pro server URL and credentials — either an **API client** (OAuth client credentials) or a **classic username/password** account. Credentials are stored in the macOS Keychain; the URL and client ID are the only values kept in preferences. The account needs read access to mobile devices and computers (and update access to edit asset tags).

### Device model data

The CPID/BDID → model mapping lives in [`AppleDeviceModels.json`](Serial%20Number%20Reader/Serial%20Number%20Reader/AppleDeviceModels.json) as a bundled resource, covering iPhone 8 and later, all iPads from 2017 onward, and Apple Silicon Macs. It can be updated without code changes.

## Building from source

Open `Serial Number Reader.xcodeproj` in Xcode and build the **Serial Number Reader** scheme. No third-party dependencies. Unit tests (Swift Testing) cover the USB descriptor parser and UDID normalisation.

The app runs outside the App Sandbox: it needs direct IOKit access for USB enumeration, and the USB-C power actions use the private `AppleHPM` port-controller interface, which requires root (the app re-launches itself with administrator privileges for those actions only).

## Architecture

- `USBDeviceMonitor` — wraps IOKit USB arrival/removal notifications and publishes an observable device list; the UI consumes only this.
- `DescriptorParser` — pure, unit-tested parsing of the Recovery/DFU USB serial descriptor and UDID normalisation.
- `ModelDatabase` — loads the bundled CPID/BDID model map.
- `JamfClient` / `JamfStore` — async Jamf Pro API client (token caching, serial/UDID lookup, asset-tag update) and its UI-facing state.
- `VDMTool` / `VDMController` — USB-PD vendor-defined-message power actions via `AppleHPM`.

## Credits

USB-PD VDM power actions are derived from [AsahiLinux/macvdmtool](https://github.com/AsahiLinux/macvdmtool) and [osy/ThunderboltPatcher](https://github.com/osy/ThunderboltPatcher) (Apache-2.0); attribution is retained in the relevant source files.
