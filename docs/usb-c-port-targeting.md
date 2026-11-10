# Sending Restart / Enter DFU only to the device's own USB-C port

Investigation of 2026-11-10. Read-only: `ioreg` and a small script that reads
IORegistry properties. No device action, no VDM, nothing run as administrator,
no code changed.

## The question

`VDMTool` opens every `AppleHPM` service, asks each one whether something is
connected (register 0x3f), and refuses (exit 4) when more than one port says
yes. A charger on a second port is enough to block Restart and Enter DFU. Can we
find which `AppleHPM` port the selected device is on and send the command there
only?

## Short answer

Yes, on Apple Silicon. The USB root port that the device hangs off carries a
property, `UsbIOPort`, that holds the IORegistry path of its physical USB-C port
(`…/AppleHPMARMSPMI/AppleHPMDeviceHALType3@…/Port-USB-C@N`). Walking up from that
port entry reaches exactly one of the `AppleHPM` services that `VDMTool` already
lists. That service's `RID` is the one to send to.

## Test setup

- MacBook Pro, M3 Pro, macOS 27 host. Three USB-C ports and MagSafe.
- An iPhone in normal mode connected directly with a USB-C cable to one port;
  a charger on a second port.

## What the registry shows

The four `AppleHPM` services (what `IOServiceMatching("AppleHPM")` returns; all
are class `AppleHPMARMSPMI`):

| AppleHPM RID | Port entry below it | ConnectionActive (first reading) |
| --- | --- | --- |
| 0 | `Port-USB-C@1` | Yes (charger) |
| 1 | `Port-USB-C@2` | Yes (iPhone) |
| 2 | `Port-USB-C@3` | No |
| 5 | `Port-MagSafe 3@1` | No |

The path from the iPhone's entry (the `IOUSBHostDevice` the app already uses,
`USBDeviceMonitor`) up the IOService plane:

```
IOUSBHostDevice (the iPhone)              locationID 0x02200000
AppleUSB30XHCIARMPort usb-drd1-port-ss    locationID 0x02200000
    UsbIOPort = IOService:/AppleARMPE/arm-io@…/AppleH15IO/nub-spmi-a0@…/
                AppleSPMIController/hpm1@A/AppleHPMARMSPMI/
                AppleHPMDeviceHALType3@A/Port-USB-C@2
    usb-c-port-number = 2
AppleT8122USBXHCI                         locationID 0x02000000
AppleARMIODevice usb-drd1
AppleH15IO → arm-io → AppleARMPE
```

So the USB side and the power-delivery side don't share a parent. The USB
controller (`usb-drd1`) and the HPM chip (`hpm1`) are separate branches under
`AppleH15IO`. What joins them is the **named relation `UsbIOPort`** on the root
port. Resolving it with `IORegistryEntryFromPath` and walking up to the first
ancestor that conforms to `AppleHPM` gives the `AppleHPMARMSPMI` with RID 1. Its
registry entry ID is the same object `VDMTool`'s matching loop gets.

Every USB root port on this Mac has the property, the USB 2 (`-hs`) and USB 3
(`-ss`) halves alike, and each controller serves exactly one USB-C port:

| Root port | locationID | UsbIOPort → | AppleHPM RID |
| --- | --- | --- | --- |
| usb-drd0-port-hs / -ss | 0x00100000 / 0x00200000 | Port-USB-C@1 | 0 |
| usb-drd1-port-hs / -ss | 0x02100000 / 0x02200000 | Port-USB-C@2 | 1 |
| usb-drd2-port-hs / -ss | 0x01100000 / 0x01200000 | Port-USB-C@3 | 2 |

### Moving the device

With the charger left where it was, the iPhone was moved to another port and
read again:

```
IOUSBHostDevice (the iPhone)              locationID 0x01200000
AppleUSB30XHCIARMPort usb-drd2-port-ss    UsbIOPort = …/hpm2@8/…/Port-USB-C@3
                                          usb-c-port-number = 3
```

`Port-USB-C@2` now reported `ConnectionActive = No`, `@3` Yes, and the charger's
`@1` still Yes. The link followed the device to the right port.

### Things that look useful but aren't

- The root port's `port` property (2 on `usb-drd2-port-ss`) is the controller's
  own port index, not the USB-C port number.
- `locationID` does say which controller, but the order (0x00 → @1, 0x02 → @2,
  0x01 → @3) is not the port number. Don't do arithmetic on it.
- `usb-c-port-number` matches the `N` in `Port-USB-C@N` and makes a good
  cross-check, but `UsbIOPort` is the stronger link because it names the exact
  entry.

## How reliable it is

- The link is direct (a path to one specific entry) and was correct before and
  after the move. Every root port on this Mac has it.
- These properties aren't documented. Apple can rename or drop them in any
  macOS release, and other Mac models may lay their ports out differently. The
  proposal below therefore refuses whenever any step of the chain is missing or
  ambiguous, so a change on Apple's side means "refused" and never "sent to the
  wrong port".

## Where it doesn't work, or wasn't tested

| Case | Status |
| --- | --- |
| Direct cable, normal mode, Apple Silicon | **Tested**, correct before and after moving ports. |
| Recovery (0x1281) | Not tested. Expected to work: the device is an `IOUSBHostDevice` on the same root port, and `UsbIOPort` sits on the root port, not on the device. |
| DFU, classic (0x1227) and "Debug USB" (0x1881) | Not tested. Same expectation as Recovery. To confirm on hardware. |
| Through a USB hub | Not tested, but it **must be refused** anyway: a VDM goes over the CC line of the Mac's own port, so it reaches whatever is plugged directly into that port (the hub), never a device behind it. The walk would still find the hub's port, so the check needs an extra rule: the device's direct parent must be the root port. |
| Through a Thunderbolt / USB4 dock | Not tested. USB then runs through the dock's own controller over a PCIe tunnel, so the chain is expected to have no `UsbIOPort`. That means refused, which is correct for the same reason as a hub. |
| Lightning device on a USB-C to Lightning cable | Maps to a port (USB 2 root port), but Lightning can't take VDMs; the app already doesn't offer the actions there. |
| A device the app can't see (a locked iPhone before first unlock, a booted Mac on a cable) | No USB entry, so no target. That's the point: such a device on another port is never reached, where today it only counts towards the refusal. |
| Intel Mac | Not tested; no Intel Mac available. `VDMTool`'s unlock key (the Apple Silicon board name) and the ACE2 sequence are Apple Silicon only, and the app needs macOS 27. As far as I know, macOS 26 was the last release for Intel Macs. So the Intel path doesn't apply today. |
| Other Apple Silicon models (Mac mini, Mac Studio, iMac, front ports, MacBook Air) | Not tested. The refusal rules cover a model where the property is missing. Worth one `ioreg` reading on each model Jordy has. |

## Proposal

The idea: the app says *which device*, and the root helper finds that device's
port itself and checks every link again. A wrong or stale value can at most be
refused, never redirected.

1. **App side (no root).** The app already has the device's registry entry ID
   (`USBDeviceMonitor`). It passes it to the helper:
   `--vdm reboot|dfu --entry <hex>`. The root side accepts only this exact
   form: one of the two actions and up to 16 hex digits, nothing else.
2. **Helper (root), find the device.** `IORegistryEntryIDMatching(id)` must give
   exactly one `IOUSBHostDevice` with vendor 0x05AC and a product ID the app
   treats as an Apple device (normal 0x1290–0x12AF, Recovery 0x1281, DFU
   0x1227, Debug USB 0x1881). Otherwise refuse.
3. **No hub.** The device's direct parent in the IOService plane must be a USB
   root port (no other `IOUSBHostDevice` between the device and the
   controller), and that parent must carry `UsbIOPort`. Otherwise refuse.
4. **Find the port.** Resolve `UsbIOPort` with `IORegistryEntryFromPath`. It
   must resolve, its `Description` must start with `Port-USB-C@`, and its
   `ConnectionActive` must be Yes. As a cross-check, `usb-c-port-number` on the
   root port must equal the `N` in `Port-USB-C@N`.
5. **Find the AppleHPM service.** Walk up from the port entry to the first
   ancestor that conforms to `AppleHPM`. Its registry entry ID must be one of the
   services `IOServiceMatching("AppleHPM")` returns, exactly once. Take its
   `RID`.
6. **Last check on that port only.** Read register 0x3f on that one port as
   today (a connection is required). Other ports aren't opened, so a charger,
   a display or a second device elsewhere no longer matters.
7. **Just before sending,** look up the device entry once more. It must still
   exist and still lead to the same AppleHPM service. This narrows the window
   for a swap between the check and the send. A small window remains, like the
   existing signature check.
8. **Refuse when unsure.** Any failed step means nothing is sent, with a new
   exit code (for example 5, "couldn't tell which USB-C port this device is
   on") and a plain message: connect the device directly to the Mac, not
   through a hub or dock. Two choices for Jordy:
   - *Strict:* refuse.
   - *Fallback:* when the chain can't be followed, fall back to today's rule
     (send only if exactly one port reports a connection). This keeps today's
     behaviour on a Mac where the property is missing. It's still safe, because
     that rule is what ships now.
9. **UI.** The app can run steps 2–5 itself without root (they're read-only)
   before asking for the administrator password. A device that can't be
   matched gets the actions dimmed with the reason, instead of a password
   prompt followed by a refusal. The rule "offered only while one device is
   attached" could then relax to "offered for a device whose port is known".
   That's a separate decision.
10. **Tests.** The chain logic can be a pure function over a small snapshot
    (entry, parent, properties) with unit tests for: direct port, hub between,
    missing `UsbIOPort`, path that doesn't resolve, non-USB-C port, port not
    active, no AppleHPM ancestor, and a mismatched `usb-c-port-number`. The real
    send stays a manual hardware check, as now.

The rules in CLAUDE.md that this would change, once Jordy decides: the root
side accepting only `--vdm reboot|dfu`, VDMTool refusing when more than one
port reports a connection, and the UI offering the actions only while one
device is attached.

## Still to confirm on hardware

- Recovery and both kinds of DFU: same reading, device on two different ports.
- A hub and a Thunderbolt dock: confirm the chain shows the hub/dock between,
  so the check refuses.
- One reading on each other Apple Silicon model available.
