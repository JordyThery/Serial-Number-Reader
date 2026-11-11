# Serial Number Reader: roadmap

Ideas for later, not planned yet. Added by Jordy on 2026-11-09, from a comparison with DFUUtility (github.com/thehallifax/DFUUtility, Apache-2.0). Nothing here is decided; each item needs Jordy's go-ahead before work starts. Ask Jordy before copying any of DFUUtility's code (see Credits in CLAUDE.md).

- **Guided DFU for Lightning devices:** a step-by-step guide for the button presses, for devices that can't take the VDM Enter DFU. It watches the USB changes (the device disappearing is the cue for "release now") and checks that the same ECID shows up in DFU. Button timing differs per model, so each model needs testing on real hardware.
- **Lightning tip:** older Lightning devices on a USB-C to Lightning cable may land in Recovery instead of DFU (USB-A to Lightning through an adapter helped in DFUUtility's tests). Left out of 1.7.0: no public Apple page supports it, and tips in the app only say what Apple's pages say. Add it if Apple documents it, or after Jordy confirms it on hardware.
- **Firmware download and library:** download IPSWs from Apple's own firmware lists, resume interrupted downloads, check the checksum, keep them on disk and manage them. Needs Jordy's decision first: it adds Apple's firmware servers to the network rule (today only Jamf, GitHub and ipsw.me).
- **Several devices one after another:** choose devices and run Restore, Revive or Restart on them in sequence, each targeted by its own ECID, with "Stop after current device". Needs Jordy's decision first: it changes the rule of one restore at a time.
- **Live check against a real Apple organization:** the release check would look up one device in an Apple Business or Apple School Manager test organization with a read-only API account, as it does for Jamf. Added by Jordy on 2026-11-10 with the Apple Business lookup (pull request #1). Needs a test organization and an API account for the release check first; reads only.

## Done

- **1.7.0:** Restart and Enter DFU go to the selected device's own USB-C port (docs/usb-c-port-targeting.md); success only once the same device (by ECID) is back in the expected mode after Enter DFU, Restart and Restore, with a 30-second watch after a missed reply; Mac DFU tips (DFU port, with Apple's page, and "allow the accessory to connect").
