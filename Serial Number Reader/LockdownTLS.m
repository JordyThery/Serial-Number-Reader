#import "LockdownTLS.h"

#import <Security/Security.h>
#import <Security/SecureTransport.h>
#include <dlfcn.h>
#include <errno.h>
#include <unistd.h>

// Secure Transport is deprecated; it remains the only system TLS stack that can
// take over an already-open socket mid-conversation, which lockdown requires.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

static NSError *TLSError(NSString *message, OSStatus status) {
    return [NSError errorWithDomain:@"LockdownTLS"
                               code:status
                           userInfo:@{NSLocalizedDescriptionKey:
                                          [NSString stringWithFormat:@"%@ (%d)", message, (int)status]}];
}

/// PEM → DER: the base64 body between the BEGIN/END lines.
static NSData *DERFromPEM(NSData *pem) {
    NSString *text = [[NSString alloc] initWithData:pem encoding:NSASCIIStringEncoding];
    if (!text) return nil;
    NSMutableString *body = [NSMutableString string];
    for (NSString *line in [text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        if (line.length == 0 || [line hasPrefix:@"-----"]) continue;
        [body appendString:line];
    }
    return [[NSData alloc] initWithBase64EncodedString:body
                                               options:NSDataBase64DecodingIgnoreUnknownCharacters];
}

/// Reads one DER tag/length header at `*offset`, leaving `*offset` at the content.
static BOOL DERReadHeader(const uint8_t *bytes, NSUInteger length, NSUInteger *offset,
                          uint8_t *tag, NSUInteger *contentLength) {
    if (*offset + 2 > length) return NO;
    *tag = bytes[(*offset)++];
    uint8_t first = bytes[(*offset)++];
    NSUInteger value = 0;
    if (first < 0x80) {
        value = first;
    } else {
        NSUInteger count = first & 0x7F;
        if (count == 0 || count > 4 || *offset + count > length) return NO;
        for (NSUInteger i = 0; i < count; i++) value = (value << 8) | bytes[(*offset)++];
    }
    if (*offset + value > length) return NO;
    *contentLength = value;
    return YES;
}

/// PKCS#8 PrivateKeyInfo → the inner PKCS#1 RSAPrivateKey, which is the form
/// SecKeyCreateWithData accepts. Pair records store PKCS#8 ("BEGIN PRIVATE KEY").
static NSData *PKCS1FromPKCS8(NSData *der) {
    const uint8_t *b = der.bytes;
    NSUInteger n = der.length, off = 0, len = 0;
    uint8_t tag = 0;
    if (!DERReadHeader(b, n, &off, &tag, &len) || tag != 0x30) return nil; // PrivateKeyInfo
    if (!DERReadHeader(b, n, &off, &tag, &len) || tag != 0x02) return nil; // version
    off += len;
    if (!DERReadHeader(b, n, &off, &tag, &len) || tag != 0x30) return nil; // algorithm
    off += len;
    if (!DERReadHeader(b, n, &off, &tag, &len) || tag != 0x04) return nil; // privateKey
    return [der subdataWithRange:NSMakeRange(off, len)];
}

/// Blocking socket I/O for Secure Transport. The socket has a receive timeout;
/// a timeout ends the connection instead of retrying indefinitely.
static OSStatus TLSRead(SSLConnectionRef connection, void *data, size_t *length) {
    int fd = *(const int *)connection;
    size_t wanted = *length, done = 0;
    while (done < wanted) {
        ssize_t n = read(fd, (uint8_t *)data + done, wanted - done);
        if (n > 0) { done += (size_t)n; continue; }
        *length = done;
        return n == 0 ? errSSLClosedGraceful : errSecIO;
    }
    *length = done;
    return noErr;
}

static OSStatus TLSWrite(SSLConnectionRef connection, const void *data, size_t *length) {
    int fd = *(const int *)connection;
    size_t wanted = *length, done = 0;
    while (done < wanted) {
        ssize_t n = write(fd, (const uint8_t *)data + done, wanted - done);
        if (n > 0) { done += (size_t)n; continue; }
        *length = done;
        return errSecIO;
    }
    *length = done;
    return noErr;
}

/// Builds an identity from an in-memory certificate and key without adding
/// them to a keychain. SecIdentityCreate is exported by Security.framework but
/// not declared publicly, hence the lookup.
typedef SecIdentityRef (*SecIdentityCreateFunction)(CFAllocatorRef, SecCertificateRef, SecKeyRef);

@implementation LockdownTLS {
    int _fd;
    SSLContextRef _context;
}

- (nullable instancetype)initWithSocket:(int)fd
                         certificatePEM:(NSData *)certificatePEM
                          privateKeyPEM:(NSData *)privateKeyPEM
                                  error:(NSError **)error {
    self = [super init];
    if (!self) return nil;
    _fd = fd;

    NSData *certificateDER = DERFromPEM(certificatePEM);
    SecCertificateRef certificate = certificateDER
        ? SecCertificateCreateWithData(NULL, (__bridge CFDataRef)certificateDER) : NULL;

    NSString *keyText = [[NSString alloc] initWithData:privateKeyPEM encoding:NSASCIIStringEncoding] ?: @"";
    NSData *keyDER = DERFromPEM(privateKeyPEM);
    if (keyDER && ![keyText containsString:@"BEGIN RSA PRIVATE KEY"]) keyDER = PKCS1FromPKCS8(keyDER);
    SecKeyRef key = NULL;
    if (keyDER) {
        NSDictionary *attributes = @{
            (id)kSecAttrKeyType: (id)kSecAttrKeyTypeRSA,
            (id)kSecAttrKeyClass: (id)kSecAttrKeyClassPrivate,
        };
        key = SecKeyCreateWithData((__bridge CFDataRef)keyDER, (__bridge CFDictionaryRef)attributes, NULL);
    }
    if (!certificate || !key) {
        if (certificate) CFRelease(certificate);
        if (key) CFRelease(key);
        if (error) *error = TLSError(@"The pairing record's certificate or key couldn't be read", errSecDecode);
        return nil;
    }

    SecIdentityCreateFunction createIdentity =
        (SecIdentityCreateFunction)dlsym(RTLD_DEFAULT, "SecIdentityCreate");
    SecIdentityRef identity = createIdentity ? createIdentity(NULL, certificate, key) : NULL;
    CFRelease(certificate);
    CFRelease(key);
    if (!identity) {
        if (error) *error = TLSError(@"Couldn't create a signing identity from the pairing record", errSecUnimplemented);
        return nil;
    }

    _context = SSLCreateContext(NULL, kSSLClientSide, kSSLStreamType);
    SSLSetIOFuncs(_context, TLSRead, TLSWrite);
    SSLSetConnection(_context, &self->_fd);
    // The device presents a certificate from its own pairing CA, not a public
    // one; the link is a local USB tunnel to a device the user chose, so the
    // server certificate is not evaluated.
    SSLSetSessionOption(_context, kSSLSessionOptionBreakOnServerAuth, true);
    OSStatus status = SSLSetCertificate(_context, (__bridge CFArrayRef)@[(__bridge id)identity]);
    CFRelease(identity);
    if (status != noErr) {
        if (error) *error = TLSError(@"Couldn't attach the pairing identity", status);
        return nil;
    }

    do {
        status = SSLHandshake(_context);
    } while (status == errSSLServerAuthCompleted);
    if (status != noErr) {
        if (error) *error = TLSError(@"The TLS handshake with the device failed", status);
        return nil;
    }
    return self;
}

- (BOOL)writeData:(NSData *)data error:(NSError **)error {
    size_t done = 0;
    while (done < data.length) {
        size_t written = 0;
        OSStatus status = SSLWrite(_context, (const uint8_t *)data.bytes + done, data.length - done, &written);
        if (status != noErr) {
            if (error) *error = TLSError(@"Writing to the device failed", status);
            return NO;
        }
        done += written;
    }
    return YES;
}

- (nullable NSData *)readLength:(NSUInteger)length error:(NSError **)error {
    NSMutableData *data = [NSMutableData dataWithLength:length];
    size_t done = 0;
    while (done < length) {
        size_t processed = 0;
        OSStatus status = SSLRead(_context, (uint8_t *)data.mutableBytes + done, length - done, &processed);
        done += processed;
        if (status != noErr && done < length) {
            if (error) *error = TLSError(@"Reading from the device failed", status);
            return nil;
        }
    }
    return data;
}

- (void)close {
    if (_context) {
        SSLClose(_context);
        CFRelease(_context);
        _context = NULL;
    }
}

- (void)dealloc {
    [self close];
}

@end

#pragma clang diagnostic pop
