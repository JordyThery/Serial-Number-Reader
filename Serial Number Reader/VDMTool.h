#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Sends Apple USB-PD vendor-defined messages (VDMs) to an attached USB-C
/// device via the Mac's own port controllers, triggering a restart or DFU
/// entry regardless of the target's software state.
///
/// Requires root (the AppleHPM user client is privileged) — the app invokes
/// itself with `--vdm <action>` through an administrator prompt.
@interface VDMTool : NSObject

/// action: @"reboot" or @"dfu". Works on any USB-C port, but only when
/// exactly one port has a device connected: with more, nothing is sent,
/// because the command addresses a port, not a device, and could reach one
/// the app can't see. Prints progress to stdout. Returns a process exit code:
/// 0 = success, 2 = nothing connected, 3 = the port didn't accept the
/// command, 4 = more than one port has a device, 1 = bad arguments /
/// internal failure.
+ (int32_t)runWithAction:(NSString *)action;

/// The exit code `runWithAction:` returns for this many ports with a device
/// before anything is sent: 0 (go ahead), 2 (none) or 4 (more than one).
+ (int32_t)exitCodeForConnectedPorts:(NSInteger)count;

/// What the user is told for that count; nil when the command can be sent.
+ (nullable NSString *)refusalForConnectedPorts:(NSInteger)count;

@end

NS_ASSUME_NONNULL_END
