#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Sends Apple USB-PD vendor-defined messages (VDMs) to an attached USB-C
/// device via the Mac's own port controllers, triggering a restart or DFU
/// entry regardless of the target's software state.
///
/// Requires root (the AppleHPM user client is privileged) — the app invokes
/// itself with `--vdm <action>` through an administrator prompt.
@interface VDMTool : NSObject

/// action: @"reboot" or @"dfu". Tries every USB-C port with a connected
/// device until one accepts the command (no designated-port requirement).
/// Prints progress to stdout. Returns a process exit code:
/// 0 = success, 2 = nothing connected, 3 = no port accepted the command,
/// 1 = bad arguments / internal failure.
+ (int32_t)runWithAction:(NSString *)action;

@end

NS_ASSUME_NONNULL_END
