#import "RecoveryCommands.h"

#import <IOKit/IOKitLib.h>
#import <IOKit/IOCFPlugIn.h>
#import <IOKit/usb/IOUSBLib.h>

@implementation RecoveryCommands

+ (BOOL)failureMeansSent:(NSString *)command {
    // "reboot" detaches the device mid-request, so the send reports an error
    // whose code varies (not responding, no device, aborted, a timeout or a
    // stall): every error on it means the device took the command.
    return [command hasPrefix:@"reboot"];
}

+ (nullable NSString *)sendCommands:(NSArray<NSString *> *)commands
                  toRegistryEntryID:(uint64_t)entryID {
    io_service_t service = IOServiceGetMatchingService(
        kIOMainPortDefault, IORegistryEntryIDMatching(entryID));
    if (!service) {
        return @"The device is no longer connected.";
    }

    SInt32 score = 0;
    IOCFPlugInInterface **plugin = NULL;
    kern_return_t kr = IOCreatePlugInInterfaceForService(
        service, kIOUSBDeviceUserClientTypeID, kIOCFPlugInInterfaceID, &plugin, &score);
    IOObjectRelease(service);
    if (kr != KERN_SUCCESS || plugin == NULL) {
        return [NSString stringWithFormat:@"Couldn’t open the USB device interface (0x%x).", kr];
    }

    IOUSBDeviceInterface **device = NULL;
    (*plugin)->QueryInterface(plugin, CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID),
                              (LPVOID *)&device);
    IODestroyPlugInInterface(plugin);
    if (device == NULL) {
        return @"Couldn’t open the USB device interface.";
    }

    IOReturn result = (*device)->USBDeviceOpen(device);
    if (result == kIOReturnExclusiveAccess) {
        (*device)->Release(device);
        return @"Another app has the device open. Quit Apple Configurator or Finder and try again.";
    }
    if (result != kIOReturnSuccess) {
        (*device)->Release(device);
        return [NSString stringWithFormat:@"Couldn’t open the USB device (0x%x).", result];
    }

    NSString *error = nil;
    for (NSString *command in commands) {
        const char *utf8 = command.UTF8String;
        IOUSBDevRequest request = {
            .bmRequestType = 0x40,              // host→device, vendor, device
            .bRequest = 0,
            .wValue = 0,
            .wIndex = 0,
            .wLength = (UInt16)(strlen(utf8) + 1),
            .pData = (void *)utf8,
        };
        result = (*device)->DeviceRequest(device, &request);
        if (result != kIOReturnSuccess) {
            if ([self failureMeansSent:command]) break;
            error = [NSString stringWithFormat:@"The command “%@” failed (0x%x).", command, result];
            break;
        }
        usleep(100000); // give iBoot a moment between commands
    }

    (*device)->USBDeviceClose(device);
    (*device)->Release(device);
    return error;
}

@end
