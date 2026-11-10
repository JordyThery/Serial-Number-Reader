#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// The helper's last line for exit code 6: the command went out, but the
/// device's reply was missed (it may already be rebooting).
extern NSString *const VDMToolReplyMissed;
/// Exit code 5 from the helper itself: the port changed between the checks.
extern NSString *const VDMToolPortChanged;
/// Exit code 2 for the device's own port.
extern NSString *const VDMToolPortNotConnected;

/// Sends Apple USB-PD vendor-defined messages (VDMs) to an attached USB-C
/// device via the Mac's own port controllers, triggering a restart or DFU
/// entry regardless of the target's software state.
///
/// Requires root (the AppleHPM user client is privileged) — the app invokes
/// itself with `--vdm <action> --entry <hex>` through an administrator prompt.
@interface VDMTool : NSObject

/// action: @"reboot" or @"dfu", sent to the one AppleHPM port controller
/// with this registry entry ID (from `USBCPort`); no other port is opened.
/// The controller must report a connection; `recheck` runs just before the
/// command is sent and must return YES (the device still leads to this
/// controller), or nothing is sent. Returns 0 = sent, 1 = bad arguments /
/// internal failure, 2 = the port reports no connection, 3 = the port didn't
/// accept the command, 5 = the controller or the device's port changed,
/// 6 = sent, but the device's reply was missed.
+ (int32_t)runWithAction:(NSString *)action
    onControllerWithEntryID:(uint64_t)entryID
                    recheck:(BOOL (^)(void))recheck;

@end

NS_ASSUME_NONNULL_END
