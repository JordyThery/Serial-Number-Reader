# Serial Number Reader: instructions for Claude

Shared code and the standards for every app: see JTKit's CLAUDE.md and ROADMAP.md (github.com/JordyThery/JTKit, or ../JTKit in the workspace).

## What the app does

A macOS app that identifies iPhones, iPads and Macs connected over USB by serial number, including devices that won't boot (Normal, Recovery and DFU mode). It looks them up in Jamf Pro (directly or through the Jamf Platform API) or Jamf School, can edit the asset tag, and can switch modes and restore over USB (Restart, Enter DFU, Enter Recovery, Boot to Normal, Restore, Revive, Remove Trust). For admins and repair staff handling devices without a readable printed serial.

## How to work on it

- App-only work: open `Serial Number Reader.xcodeproj`. This folder's notes load and it builds against the published JTKit.
- Anything that changes JTKit: work in `~/Developer/Apps.xcworkspace`.
- Never have the app open in both at once.
- Build releases from the app's own project, so they use the published JTKit version.
- After merging into main, push main to origin straight away (keep GitHub in sync).
- Jordy is not a programmer: explain changes in plain language, in small steps.

## Architecture

All sources are in one folder, `Serial Number Reader/`.

- USB: `USBDeviceMonitor` (IOKit arrival/removal, mode from the product ID; the UI reads only this), `USBDevice`, `DescriptorParser` (Recovery/DFU serial descriptor, UDID normalising), `ModelDatabase` + `AppleDeviceModels.json` (CPID/BDID → model; update the JSON for new hardware, no code change).
- Booted devices: `Usbmux` (usbmuxd + lockdown: unpaired device info, Enter Recovery), `LockdownTLS.m` (TLS on the lockdown socket for paired sessions).
- Power and mode actions: `DeviceActionController` (runs every action, one at a time, app-wide), `VDMTool.mm` + `AppleHPMLib.h` (USB-PD VDMs for Restart / Enter DFU), `RecoveryCommands.m` (Boot to Normal). `BridgingHeader.h` exposes the Objective-C parts.
- Restore: `Configurator` (runs Apple Configurator's `cfgutil`), `RestoreController` (the running job, IPSW checks against ipsw.me), `RestoreViews`.
- Jamf: `JamfClient.swift` (`JamfService`, `JamfConfiguration`, `JamfDeviceRecord`, the app's own error hints), `JamfConnection` (+ `JamfConnectionStore`), `JamfStore` (lookups per device, asset tag, Test Connection), `LegacySettingsConversion`.
- UI and app: `MyApp`, `ContentView`, `DeviceDetailView`, `SettingsView`, `AboutInfo` (About and the acknowledgement), `SessionExport` (CSV, copy all serials).
- Demo mode: `AppDemo` (JTKit's `DemoMode`, saved under `demoMode`, and the sandbox run), `DemoUSB` (the pretend iPhone, `PretendIPhone`: `DemoWorld` device 42, `ZZDEMOP42RX`, in Contoso Jamf Pro), `USBHardware` (the one doorway to real devices: lockdown, iBoot, VDMs, `cfgutil`; `LiveUSBHardware` refuses the pretend iPhone's identifiers). Lookups use JTKit's demo connections "Contoso Jamf Pro (Demo)" and "Contoso Academy (Demo)" (`JamfStore.demoChoice`).

From JTKit: `JamfPlatform.Client` (Jamf Pro direct and through the gateway), the `JamfPro` lookups and asset-tag calls, `JamfSchool.Client`, `RequestRecorder`, `JamfRegion`, `JamfPlatformError`/`JamfSchoolError`, `ConnectionStore` + `ConnectionPicker` + `ConnectionCommands`, `KeychainSecretStore`, `ActivityLog` + `ActivityLogWindow`, `SettingsWindow`, `AboutWindow` + `Acknowledgement`, `UpdateChecker`. Tests use `MockServer` from `JTKitTestSupport`.

App-specific, stays here: everything USB, lockdown, VDM, cfgutil and restore; `JamfDeviceRecord` (mapped from JTKit's records) and the app's hints.

When something is needed that JTKit could share, extend JTKit instead of adding another copy here.

Build facts: not sandboxed (`ENABLE_APP_SANDBOX = NO`, needed for IOKit and the root VDM path), hardened runtime, Swift 5 language mode with main-actor default isolation. It uses private interfaces (AppleHPM, `SecIdentityCreate`), so it can never go in the App Store.

## Rules

- **No real device identifiers anywhere in the repo** (it is public): no real serial numbers, UDIDs, ECIDs or device names containing them in code, tests, comments, fixtures or commit messages. Copy hardware output only after replacing the values with obvious placeholders. Before every commit, scan the staged diff for anything that looks like a real identifier and for Platform API credentials. Don't bring up identifiers already in the git history.
- **The app must never require trust.** macOS always shows "Trust This Computer?" on connect; that is normal, not caused by the app. Don't flag it or ask for trust tests. Only Enter Recovery on iOS 27 uses an existing pairing.
- System-log (`os.Logger`) messages that can hold an identifier or a server answer are `.private`.
- Every USB action that ran (Restart, Enter DFU, Enter Recovery, Boot to Normal, Restore, Revive, Remove Trust) writes an "Action" entry to the activity log, done or failed, with the device's identifiers for the masked export. A cancelled administrator prompt writes nothing.
- The app sends no MDM commands; all actions go over USB.
- **Demo mode never reaches a real device:** while it is on, `USBDeviceMonitor` doesn't watch USB (real devices are hidden, the sidebar says so) and every action, Restore and Revive goes to `DemoUSB`; a real device is refused, and outside demo mode the pretend iPhone is refused (`DemoModeTests`). Anything new that touches a device goes through `USBHardware`. The Demo Mode switch is dimmed while an action or restore runs. Test Connection stays real.
- Restore: one device at a time; the confirmation has Cancel as default and a destructive "Erase & Restore"; the IPSW is checked against the model and Apple's signing status before anything is erased; quitting during a restore warns.
- Restart / Enter DFU target the first port with a connected device, so the UI offers them only while one device is attached.
- Network use: only the Jamf servers, GitHub (update check) and ipsw.me (model identifier and build only). Keep it that way.
- The Platform API connection is environment-scoped only (no tenant-ID option). Default region: EU.
- **Preserve stored data:** connections as JSON under UserDefaults `jamfConnections`; secrets in Keychain service `be.jordythery.SerialNumberReader.jamf`. The pre-connections keys (`jamfServerURL`, `jamfAuthMethod`, …) and their Keychain items are only read once by `LegacySettingsConversion` (flag `jamfConnectionsConverted`), never changed or deleted.
- Credits: Restart / Enter DFU derive from macvdmtool and ThunderboltPatcher (Apache-2.0). The licence in About must stay identical to `THIRD-PARTY-NOTICES.md` (a test checks it). No other third-party code in the app itself; ask Jordy before adding any.

## USB, lockdown and cfgutil facts (verified on hardware)

- **Before first unlock (BFU)** a booted iPhone/iPad doesn't appear on USB at all (USB restricted mode), not in Finder or Configurator either. Not an app bug: ask whether it was unlocked once since boot. Recovery and DFU always enumerate, whatever the lock state.
- **Product IDs** (vendor 0x05AC): Recovery 0x1281 (descriptor has the serial, SRNM, and ECID); classic DFU 0x1227 (descriptor with CPID/ECID, older devices); normal mode 0x1290–0x12AF.
- **Current hardware in DFU** (verified on iPhone 17e, M3 iPad Air, Apple Silicon Mac, macOS 26 host) shows up as "Debug USB" 0x1881: no serial descriptor, no identifiers, access needs a private Apple entitlement. The app can only detect presence (`isOpaqueDFU`) and guides the user to Recovery, where the serial is readable. If a phantom "Apple Device (DFU)" row ever appears next to a phone in normal mode, 0x1881 also appears outside DFU and the classification needs refining.
- A booted Mac never appears (it is a USB host).
- **Unpaired lockdown reads work** while the trust prompt is open: ProductType, ProductVersion, BuildVersion, DeviceClass, DeviceName. SerialNumber, ModelNumber and RegionInfo are refused (GetProhibited). ProductName says "iPhone OS" on every device, so the OS name comes from DeviceClass.
- **Enter Recovery on iOS/iPadOS 27:** an unpaired `EnterRecovery` is refused with `SessionInactive` (worked on iOS 26). It works over a paired session: usbmuxd `ReadPairRecord` (no root) → lockdown `StartSession` {HostID, SystemBUID} → `EnableSessionSSL` → TLS with the pair record's host certificate and key (no server check) → `EnterRecovery`. Secure Transport is used because Network.framework can't start TLS on an open socket; the client identity is built with `SecIdentityCreate` via `dlsym`, because no public API builds one from PEM. Pair records hold PKCS#8 keys; `SecKeyCreateWithData` needs PKCS#1.
- **Boot to Normal** from Recovery: iBoot control transfers `setenv auto-boot true`, `saveenv`, `reboot`. A send error on `reboot` means success (the device detaches). Works on iOS 27.
- **VDM actions** (AppleHPM) exist only for reboot and DFU, need root and a USB-C target (Lightning devices can't). The app re-launches its own binary with `--vdm <reboot|dfu>` through `osascript … with administrator privileges`, handled in `MyApp.main()` before the GUI starts; osascript returns -128 when the prompt is cancelled. "Recovery" in tools like DFU Blaster is lockdown `EnterRecovery`, not a VDM.
- **cfgutil** (inside Apple Configurator, no admin password needed): `--format JSON list` identifies devices in every mode, including opaque DFU (ECID, UDID, deviceType, locationID). Link to the USB device by ECID/UDID; use locationID only for DFU (it once differed for a booted device). cfgutil has no enter-recovery command.
- `cfgutil --progress --format JSON -e <ECID> restore|revive` writes JSON Lines: `Step`/`StepComplete`, `Progress` 0…1 (only while unzipping; -1 = indeterminate), then `CommandOutput`. Exit 0 = success. Reboots and disconnects during the job are expected.
- **Revive keeps data**, from DFU and from Recovery. During a revive the device goes DFU → Recovery 0x1281 (this stage has no SRNM) → restore OS 0x12AC → normal, so "Enter DFU → Revive" can't be used to read the serial.
- Apple stops signing older OS versions quickly; downgrades are impossible, and old-OS test devices can't be restored to that OS again.

## Testing

- Unit tests: Swift Testing in `Serial Number Reader Tests`, ⌘U in the app's project. They cover the descriptor parser, UDIDs and ECIDs, cfgutil output, IPSW checks, connection conversion, Jamf networking (on JTKit's `MockServer`), session export, the action log entries and the acknowledgement.
- As the unit-test host, the app uses a throwaway UserDefaults domain and no Keychain (`JamfConnectionStore.forUnitTestHost()`), so tests never touch real saved connections. The connection-conversion suite is `.serialized`.
- USB, lockdown, VDM and restore can't run in tests or the dev harness; they need a real device. Jordy checks them by hand.
- Test data uses placeholder identifiers and `example.jamfcloud.com`-style hosts only.
- Never run the long UI suites of Jamf Deployer or AppSettings2Blueprint unless Jordy asks for one by name.
- Release check and live sandbox checks: see JTKit ROADMAP step 11 (not yet built for this app). Live checks run only against tenants on the local allow-list outside git and clean up after themselves.

## Releasing

1. Bump `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in the project.
2. Update the README if features changed (its screenshot must show no real identifiers).
3. Archive from the app's own project, sign with Developer ID, notarize, and zip.
4. Tag `vX.Y.Z`, create the GitHub release with notes (the in-app updater shows them) and attach the zip.
5. Website: only when the app has its own page on jordythery.be and the release changes the app enough to make that page untrue or incomplete, update the page.

Before any of this, follow the release gate in JTKit/ROADMAP.md.
