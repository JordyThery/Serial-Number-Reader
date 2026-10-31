# Changelog

## 1.4.0 — 2026-10-31

### New

- **Saved connections.** Settings › Connections holds several Jamf Pro, Jamf
  Platform API and Jamf School connections; the picker in the toolbar and the
  Connection menu switch between them. Settings from earlier versions are
  converted once, automatically.
- **Activity log** (Window › Activity Log, ⇧⌘L): every sign-in, lookup, asset
  tag change, connection test and USB action, with an export for bug reports
  that masks serial numbers, UDIDs and ECIDs.
- **Demo Mode**: a pretend iPhone and sample Jamf servers, without a device or
  a tenant. Nothing is sent to a device or a tenant.
- **Clear Disconnected** is also in the File menu.

### Changed

- **Restart and Enter DFU only work while nothing else is connected to
  another USB-C port of your Mac.** Unplug any other device, hub or dock, and
  also a USB-C charger: on a MacBook that charges over USB-C, unplug the
  charger first. Charging with MagSafe is fine. If something else is
  connected, the app asks for the administrator password and then says it
  didn’t send the command; nothing happens to any device. The reason: the
  command goes to a port, not to a device, and could otherwise reach a device
  the app can’t see, such as a locked iPhone or another Mac on a cable.
- **Before asking for the administrator password**, Restart and Enter DFU
  check that the app on disk is the signed app that is running. If it isn’t,
  the app says so and asks for nothing.
- **A Restore with a specific IPSW needs a known model.** When the device’s
  model is unknown, the IPSW can’t be checked, so the sheet says so and only
  the latest version can be installed. It used to say the IPSW "supports this
  device".
- **Enter Recovery over a trusted connection checks the device’s
  certificate** against this Mac’s pairing record, and refuses anything else.
- **No USB action starts while a Restore or Revive runs**, and no Restore or
  Revive while an action runs, also outside the detail view.
- Test Connection says "Connected · Jamf Pro" (or Jamf School), like the other
  apps.
- Clearer, consistent wording: "No Jamf connection in use" instead of "not
  configured", the same words for a missing serial number in the list and in
  the details, "Jamf Name" for the name in Jamf, and messages written as
  sentences.

### Fixed

- **A Mac in DFU is found in Jamf Pro.** It is looked up by its UDID as a
  computer when no mobile device matches; it used to show "No matching device".
- **Boot to Normal reports success** whenever the device detaches on the final
  reboot, whatever error code the send returns.
- **The CSV export includes the UDID of a DFU device** identified through
  Apple Configurator, as the details show it.
- Error messages from the device no longer include the device’s whole reply,
  which could hold its identifiers.
- The quit warning during a Revive says "revive", and its Quit Anyway button
  is marked as destructive.
- Long-running USB work no longer ties up the threads the rest of the app
  uses, and a chatty helper can’t stall on a full output pipe.

### Fixes found by the release check

- **After saving an asset tag, the app shows what Jamf stored.** It used to
  show the value as typed; now it reads the record back after the save (if
  that read fails, it shows the saved value as before).
- **An asset tag saved while switching connections no longer shows up under
  the new connection.** The save still goes to the server that was in use, but
  its result isn’t put in the new connection’s list.
- **A refused Restore or Revive says why.** The sheet closed without a word
  when the restore couldn’t start (another one still running, or a real device
  while Demo Mode is on); now it stays open with a message.
- **Demo Mode never asks ipsw.me.** Opening Restore on the pretend iPhone
  checked Apple’s signing status for its model online; it now shows a made-up
  signed release ("26.0"). Under tests no lookups are made at all.
- **The unit tests always start with Demo Mode off.** A switch left on in the
  test host’s settings by an earlier run could turn it on for one run.
- **The tests leave no settings files behind.** Each run left an empty
  settings file per test in `~/Library/Preferences`; their settings now live in
  a temporary folder instead. An empty template test was removed.
- The project no longer lists a leftover `SerialNumberReaderUITests` folder
  from a first attempt at adding the UI test target.

## 1.3 — 2026-10-25

- **Restore and Revive** for devices in DFU or Recovery mode, through Apple
  Configurator, with the IPSW checked against the model and Apple’s signing
  status before anything is erased.
- **Jamf School** support alongside Jamf Pro.
- **Enter Recovery on iOS 27 and later** over a trusted connection, and
  **Remove Trust**.
- **DFU identification** (model, ECID and UDID) through Apple Configurator.

## 1.2 — 2026-10-23

- **Jamf Platform API** connections, scoped to a platform environment.
- Model, OS version and device name for booted devices.
- **Session export** as CSV, and Copy All Serial Numbers.

## 1.1.1 — 2026-10-15

- Update checker: a daily check for a new release on GitHub, and Check for
  Updates… in the app menu.

## 1.1 — 2026-10-07

- **Enter Recovery** and **Boot to Normal** without pressing buttons on the
  device.
- Restart and Enter DFU are disabled while more than one device is connected.

## 1.0 — 2026-10-07

- First public release: serial numbers of iPhones and iPads in Normal,
  Recovery and DFU mode, Jamf Pro lookup with an editable asset tag, and
  Restart / Enter DFU over USB-C.
