#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// TLS client over an already-connected lockdown socket, authenticated with
/// the host certificate and key from the Mac's pairing record for the device.
///
/// Lockdown switches to TLS in the middle of an open connection (after
/// StartSession), which Network.framework can't do on an existing socket, so
/// this uses Secure Transport. Deprecated, but still shipped by macOS.
@interface LockdownTLS : NSObject

/// Performs the TLS handshake on `fd`. The socket stays owned by the caller.
- (nullable instancetype)initWithSocket:(int)fd
                         certificatePEM:(NSData *)certificatePEM
                          privateKeyPEM:(NSData *)privateKeyPEM
                                  error:(NSError **)error;

- (BOOL)writeData:(NSData *)data error:(NSError **)error;

/// Reads exactly `length` bytes.
- (nullable NSData *)readLength:(NSUInteger)length error:(NSError **)error;

- (void)close;

@end

NS_ASSUME_NONNULL_END
