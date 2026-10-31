#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Sends iBoot console commands to a Recovery-mode device over USB control
/// requests (the same mechanism as `irecovery`). Used to boot a device back
/// to normal mode: `setenv auto-boot true`, `saveenv`, `reboot`.
@interface RecoveryCommands : NSObject

/// Sends the commands, in order, to the Recovery-mode device with the given
/// IORegistry entry ID. Returns nil on success or a human-readable error.
/// Blocking — call off the main thread.
+ (nullable NSString *)sendCommands:(NSArray<NSString *> *)commands
                  toRegistryEntryID:(uint64_t)entryID
    NS_SWIFT_NAME(send(_:toRegistryEntryID:));

/// Whether a send error on this command still means it was sent: true for
/// `reboot`, which detaches the device mid-request. The earlier commands
/// stay strict.
+ (BOOL)failureMeansSent:(NSString *)command NS_SWIFT_NAME(failureMeansSent(_:));

@end

NS_ASSUME_NONNULL_END
