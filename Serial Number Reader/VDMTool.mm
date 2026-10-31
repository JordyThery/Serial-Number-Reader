#import "VDMTool.h"
#import "AppleHPMLib.h"

#include <IOKit/IOKitLib.h>
#include <CoreFoundation/CoreFoundation.h>
#include <sstream>
#include <string>
#include <vector>

// Portions derived from github.com/AsahiLinux/macvdmtool (Apache-2.0) and
// github.com/osy/ThunderboltPatcher. The VDM payloads and ACE2 host-interface
// command sequences originate there. Reworked to:
//   * work on any USB-C port (no designated DFU port requirement, like
//     OwDFU), but refuse when more than one port has a device connected:
//     iterator order isn't physical order, and a device the app can't see
//     (a locked iPhone, another Mac on a cable) must never get the command;
//   * expose reboot/dfu as a library call returning a status code.

namespace {

struct Failure {
    std::string message;
};

// Serialize a trivially-copyable value into a byte stream (little-endian on
// Apple Silicon, matching the controller's expectation).
template <typename T>
void put(std::stringstream &str, const T &value) {
    char data[sizeof(T)];
    memcpy(data, &value, sizeof(T));
    str.write(data, sizeof(T));
}

template <typename T>
void get(std::stringstream &str, T &value) {
    char data[sizeof(T)];
    str.read(data, sizeof(T));
    memcpy(&value, data, sizeof(T));
}

struct HPMPort {
    IOCFPlugInInterface **plugin = nullptr;
    AppleHPMLib **device = nullptr;
    int32_t rid = -1;
    bool inDebugMode = false;

    HPMPort(io_service_t service, int32_t rid) : rid(rid) {
        SInt32 score;
        IOReturn ret = IOCreatePlugInInterfaceForService(
            service, kAppleHPMLibType, kIOCFPlugInInterfaceID, &plugin, &score);
        if (ret != kIOReturnSuccess)
            throw Failure{"IOCreatePlugInInterfaceForService failed."};

        HRESULT res = (*plugin)->QueryInterface(
            plugin, CFUUIDGetUUIDBytes(kAppleHPMLibInterface), (LPVOID *)&device);
        if (res != S_OK)
            throw Failure{"QueryInterface failed."};
    }

    ~HPMPort() {
        if (plugin) {
            // Restore the port only if it was put into debug mode;
            // ignore errors on teardown.
            if (inDebugMode)
                command(0, 'DBMa', std::string("\x00", 1));
            IODestroyPlugInInterface(plugin);
        }
    }

    HPMPort(const HPMPort &) = delete;
    HPMPort &operator=(const HPMPort &) = delete;

    std::string readRegister(uint64_t chipAddr, uint8_t dataAddr, int flags = 0) {
        std::string ret;
        ret.resize(64);
        uint64_t rlen = 0;
        IOReturn x = (*device)->Read(device, chipAddr, dataAddr, &ret[0], 64, flags, &rlen);
        if (x != 0)
            throw Failure{"Reading the USB-C port failed."};
        return ret;
    }

    int command(uint64_t chipAddr, uint32_t cmd, std::string args = "") {
        // A failed write would leave stale arguments in the register for the
        // command below: never send the command then.
        if (args.length() && (*device)->Write(device, chipAddr, 9, args.data(), args.length(), 0) != kIOReturnSuccess)
            throw Failure{"Couldn’t write the command to the USB-C port."};
        auto ret = (*device)->Command(device, chipAddr, cmd, 0);
        if (ret)
            return -1;
        auto res = readRegister(chipAddr, 9);
        return res[0] & 0xfu;
    }
};

// Interpret a register read as a NUL-terminated string. The raw buffer is 64
// bytes and may contain no NUL at all — never assume one.
std::string TrimAtNul(std::string value) {
    auto nul = value.find('\0');
    if (nul != std::string::npos)
        value.erase(nul);
    return value;
}

// The Mac's 4-char model code, used as the ACE2 unlock key.
uint32_t GetUnlockKey() {
    CFMutableDictionaryRef matching = IOServiceMatching("IOPlatformExpertDevice");
    if (!matching)
        throw Failure{"IOServiceMatching failed (IOPED)."};
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, matching);
    if (!service)
        throw Failure{"IOServiceGetMatchingService failed (IOPED)."};
    io_name_t deviceName;
    IOReturn r = IORegistryEntryGetName(service, deviceName);
    IOObjectRelease(service);
    if (r != kIOReturnSuccess)
        throw Failure{"IORegistryEntryGetName failed (IOPED)."};
    return (deviceName[0] << 24) | (deviceName[1] << 16) | (deviceName[2] << 8) | deviceName[3];
}

void UnlockAce(HPMPort &inst, int no, uint32_t key) {
    std::stringstream args;
    put(args, key);
    if (inst.command(no, 'LOCK', args.str())) {
        if (inst.command(no, 'Gaid'))
            throw Failure{"Couldn’t unlock the USB-C port."};
        if (inst.command(no, 'LOCK', args.str()))
            throw Failure{"Couldn’t unlock the USB-C port."};
    }
}

void DoVDM(HPMPort &inst, int no, std::vector<uint32_t> vdm) {
    auto rs = inst.readRegister(no, 0x4d);
    uint8_t rxst = rs[0];

    std::stringstream args;
    put(args, (uint8_t)(((3 << 4) | vdm.size())));
    for (uint32_t i : vdm)
        put(args, i);

    if (inst.command(no, 'VDMs', args.str()))
        throw Failure{"Couldn’t send the command to the device."};

    int i;
    for (i = 0; i < 16; i++) {
        rs = inst.readRegister(no, 0x4d);
        if ((uint8_t)rs[0] != rxst)
            break;
    }
    if (i >= 16)
        throw Failure{"The device didn’t reply to the command."};

    uint32_t vdmhdr;
    std::stringstream reply;
    reply.str(rs);
    get(reply, rxst);
    get(reply, vdmhdr);

    if (vdmhdr != (vdm[0] | 0x40))
        throw Failure{"The device rejected the command."};
}

void DoReboot(HPMPort &inst, int no) {
    DoVDM(inst, no, {0x5ac8012, 0x105, 0x80000000});
}

void DoDFU(HPMPort &inst, int no) {
    DoVDM(inst, no, {0x5ac8012, 0x106, 0x80010000});
}

// Whether a device is connected to this port (register 0x3f, bit 0).
bool IsConnected(io_service_t service, int32_t rid) {
    HPMPort inst(service, rid);
    return inst.readRegister(0, 0x3f)[0] & 1;
}

// Put a single port into debug (DBMa) mode and run the action.
void RunOnPort(io_service_t service, int32_t rid, const std::string &action, uint32_t key) {
    HPMPort inst(service, rid);
    int no = 0;

    auto status = TrimAtNul(inst.readRegister(no, 0x03));
    if (status != "DBMa") {
        UnlockAce(inst, no, key);
        // From here the port may have entered debug mode even if verification
        // fails below — always restore it on teardown.
        inst.inDebugMode = true;
        if (inst.command(no, 'DBMa', std::string("\x01", 1)))
            throw Failure{"Couldn’t prepare the USB-C port."};
        status = TrimAtNul(inst.readRegister(no, 0x03));
        if (status != "DBMa")
            throw Failure{"Couldn’t prepare the USB-C port."};
    } else {
        inst.inDebugMode = true;
    }

    if (action == "reboot")
        DoReboot(inst, no);
    else if (action == "dfu")
        DoDFU(inst, no);
    else
        throw Failure{"Unknown action."};
}

} // namespace

@implementation VDMTool

+ (int32_t)exitCodeForConnectedPorts:(NSInteger)count {
    if (count == 0) return 2;
    if (count > 1) return 4;
    return 0;
}

+ (nullable NSString *)refusalForConnectedPorts:(NSInteger)count {
    switch ([self exitCodeForConnectedPorts:count]) {
    case 2: return @"No device is connected to a USB-C port.";
    case 4: return @"More than one USB-C port has something connected, such as another device, a charger or a hub, so the command could reach the wrong one. Disconnect everything except this device and try again.";
    default: return nil;
    }
}

+ (int32_t)runWithAction:(NSString *)action {
    std::string act = action.UTF8String;
    if (act != "reboot" && act != "dfu") {
        fprintf(stderr, "Unknown action: %s\n", act.c_str());
        return 1;
    }

    try {
        uint32_t key = GetUnlockKey();

        CFMutableDictionaryRef matching = IOServiceMatching("AppleHPM");
        if (!matching)
            throw Failure{"IOServiceMatching failed."};
        io_iterator_t iter = 0;
        if (IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iter) != kIOReturnSuccess)
            throw Failure{"IOServiceGetMatchingServices failed."};

        // First every port, then decide: exactly one port with a device, or nothing is sent.
        std::vector<std::pair<io_service_t, int32_t>> connected;
        io_service_t device;
        while ((device = IOIteratorNext(iter))) {
            int32_t rid = -1;
            CFNumberRef data = (CFNumberRef)IORegistryEntryCreateCFProperty(
                device, CFSTR("RID"), kCFAllocatorDefault, 0);
            if (data) {
                CFNumberGetValue(data, kCFNumberSInt32Type, &rid);
                CFRelease(data);
            }
            bool isConnected = false;
            try {
                isConnected = IsConnected(device, rid);
            } catch (const Failure &f) {
                // A port that can't be read can't be sent a command either.
                fprintf(stderr, "Port RID %d: %s\n", rid, f.message.c_str());
            }
            if (isConnected)
                connected.emplace_back(device, rid);
            else
                IOObjectRelease(device);
        }
        IOObjectRelease(iter);

        int32_t code = [self exitCodeForConnectedPorts:(NSInteger)connected.size()];
        if (code != 0) {
            fprintf(stderr, "%s\n", [self refusalForConnectedPorts:(NSInteger)connected.size()].UTF8String);
            for (auto &port : connected) IOObjectRelease(port.first);
            return code;
        }

        auto port = connected.front();
        try {
            RunOnPort(port.first, port.second, act, key);
        } catch (const Failure &f) {
            IOObjectRelease(port.first);
            fprintf(stderr, "%s\n", f.message.c_str());
            return 3;
        }
        IOObjectRelease(port.first);
        printf("Sent '%s' on port RID %d\n", act.c_str(), port.second);
        return 0;
    } catch (const Failure &f) {
        fprintf(stderr, "%s\n", f.message.c_str());
        return 1;
    } catch (...) {
        fprintf(stderr, "Something unexpected went wrong.\n");
        return 1;
    }
}

@end
