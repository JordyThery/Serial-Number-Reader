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
/// The device must present the pairing record's device certificate (or one
/// issued by its root certificate); any other peer is refused.
- (nullable instancetype)initWithSocket:(int)fd
                         certificatePEM:(NSData *)certificatePEM
                          privateKeyPEM:(NSData *)privateKeyPEM
                   deviceCertificatePEM:(nullable NSData *)deviceCertificatePEM
                     rootCertificatePEM:(nullable NSData *)rootCertificatePEM
                                  error:(NSError **)error;

/// PEM → DER: the base64 body between the BEGIN/END lines.
+ (nullable NSData *)DERFromPEM:(NSData *)pem NS_SWIFT_NAME(der(fromPEM:));

/// A PEM private key ("BEGIN PRIVATE KEY", PKCS#8, as pair records store it,
/// or "BEGIN RSA PRIVATE KEY") as the PKCS#1 data SecKeyCreateWithData takes.
+ (nullable NSData *)PKCS1KeyFromPEM:(NSData *)pem NS_SWIFT_NAME(pkcs1Key(fromPEM:));

/// Whether the device's TLS certificate belongs to the pairing: it is the
/// pairing record's device certificate, or is issued by its root certificate.
+ (BOOL)peerCertificate:(NSData *)peerDER
    matchesDeviceCertificatePEM:(nullable NSData *)deviceCertificatePEM
             rootCertificatePEM:(nullable NSData *)rootCertificatePEM
    NS_SWIFT_NAME(peerCertificate(_:matchesDeviceCertificatePEM:rootCertificatePEM:));

- (BOOL)writeData:(NSData *)data error:(NSError **)error;

/// Reads exactly `length` bytes.
- (nullable NSData *)readLength:(NSUInteger)length error:(NSError **)error;

- (void)close;

@end

NS_ASSUME_NONNULL_END
