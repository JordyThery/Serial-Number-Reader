#import "RecoveryCommands.h"

#import <IOKit/IOKitLib.h>
#import <IOKit/IOCFPlugIn.h>
#import <IOKit/usb/IOUSBLib.h>

@implementation RecoveryCommands

+ (nullable NSString *)sendCommands:(NSArray<NSString *> *)commands
                  toRegistryEntryID:(uint64_t)entryID {
    io_service_t service = IOServiceGetMatchingService(
        kIOMainPortDefault, IORegistryEntryIDMatching(entryID));
    if (!service) {
        return @"Device no longer present in the IORegistry";
    }

    SInt32 score = 0;
    IOCFPlugInInterface **plugin = NULL;
    kern_return_t kr = IOCreatePlugInInterfaceForService(
        service, kIOUSBDeviceUserClientTypeID, kIOCFPlugInInterfaceID, &plugin, &score);
    IOObjectRelease(service);
    if (kr != KERN_SUCCESS || plugin == NULL) {
        return [NSString stringWithFormat:@"Couldn't create USB plug-in interface (0x%x)", kr];
    }

    IOUSBDeviceInterface **device = NULL;
    (*plugin)->QueryInterface(plugin, CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID),
                              (LPVOID *)&device);
    IODestroyPlugInInterface(plugin);
    if (device == NULL) {
        return @"Couldn't obtain the USB device interface";
    }

    IOReturn result = (*device)->USBDeviceOpen(device);
    if (result == kIOReturnExclusiveAccess) {
        (*device)->Release(device);
        return @"Another app has the device open — quit Apple Configurator/Finder and retry";
    }
    if (result != kIOReturnSuccess) {
        (*device)->Release(device);
        return [NSString stringWithFormat:@"Couldn't open the USB device (0x%x)", result];
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
            // "reboot" detaches the device mid-request — only the detach
            // errors count as success; anything else is a real failure.
            BOOL detached = result == kIOReturnNotResponding
                || result == kIOReturnNoDevice
                || result == kIOReturnAborted;
            if ([command hasPrefix:@"reboot"] && detached) break;
            error = [NSString stringWithFormat:@"Command “%@” failed (0x%x)", command, result];
            break;
        }
        usleep(100000); // give iBoot a moment between commands
    }

    (*device)->USBDeviceClose(device);
    (*device)->Release(device);
    return error;
}

@end
