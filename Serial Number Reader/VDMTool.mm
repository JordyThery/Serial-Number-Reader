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
//   * try every USB-C port that has a device connected (no designated DFU
//     port requirement — works on any port, like OwDFU), and
//   * expose reboot/dfu as a library call returning a status code.

namespace {

struct Failure {
    std::string message;
};

// Serialise a trivially-copyable value into a byte stream (little-endian on
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

    HPMPort(io_service_t service, int32_t rid) : rid(rid) {
        SInt32 score;
        IOReturn ret = IOCreatePlugInInterfaceForService(
            service, kAppleHPMLibType, kIOCFPlugInInterfaceID, &plugin, &score);
        if (ret != kIOReturnSuccess)
            throw Failure{"IOCreatePlugInInterfaceForService failed"};

        HRESULT res = (*plugin)->QueryInterface(
            plugin, CFUUIDGetUUIDBytes(kAppleHPMLibInterface), (LPVOID *)&device);
        if (res != S_OK)
            throw Failure{"QueryInterface failed"};
    }

    ~HPMPort() {
        if (plugin) {
            // Best-effort exit of debug mode; ignore errors on teardown.
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
            throw Failure{"readRegister failed"};
        return ret;
    }

    int command(uint64_t chipAddr, uint32_t cmd, std::string args = "") {
        if (args.length())
            (*device)->Write(device, chipAddr, 9, args.data(), args.length(), 0);
        auto ret = (*device)->Command(device, chipAddr, cmd, 0);
        if (ret)
            return -1;
        auto res = readRegister(chipAddr, 9);
        return res[0] & 0xfu;
    }
};

// The Mac's 4-char model code, used as the ACE2 unlock key.
uint32_t GetUnlockKey() {
    CFMutableDictionaryRef matching = IOServiceMatching("IOPlatformExpertDevice");
    if (!matching)
        throw Failure{"IOServiceMatching failed (IOPED)"};
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, matching);
    if (!service)
        throw Failure{"IOServiceGetMatchingService failed (IOPED)"};
    io_name_t deviceName;
    IOReturn r = IORegistryEntryGetName(service, deviceName);
    IOObjectRelease(service);
    if (r != kIOReturnSuccess)
        throw Failure{"IORegistryEntryGetName failed (IOPED)"};
    return (deviceName[0] << 24) | (deviceName[1] << 16) | (deviceName[2] << 8) | deviceName[3];
}

void UnlockAce(HPMPort &inst, int no, uint32_t key) {
    std::stringstream args;
    put(args, key);
    if (inst.command(no, 'LOCK', args.str())) {
        if (inst.command(no, 'Gaid'))
            throw Failure{"Failed to unlock port"};
        if (inst.command(no, 'LOCK', args.str()))
            throw Failure{"Failed to unlock port"};
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
        throw Failure{"Failed to send VDM"};

    int i;
    for (i = 0; i < 16; i++) {
        rs = inst.readRegister(no, 0x4d);
        if ((uint8_t)rs[0] != rxst)
            break;
    }
    if (i >= 16)
        throw Failure{"No reply to VDM"};

    uint32_t vdmhdr;
    std::stringstream reply;
    reply.str(rs);
    get(reply, rxst);
    get(reply, vdmhdr);

    if (vdmhdr != (vdm[0] | 0x40))
        throw Failure{"VDM rejected by device"};
}

void DoReboot(HPMPort &inst, int no) {
    DoVDM(inst, no, {0x5ac8012, 0x105, 0x80000000});
}

void DoDFU(HPMPort &inst, int no) {
    DoVDM(inst, no, {0x5ac8012, 0x106, 0x80010000});
}

// Put a single port into debug (DBMa) mode and run the action. Returns true on
// success. `connected` is set when a device was present on this port.
bool RunOnPort(io_service_t service, int32_t rid, const std::string &action,
               uint32_t key, bool &connected) {
    connected = false;
    HPMPort inst(service, rid);
    int no = 0;

    auto t = inst.readRegister(no, 0x3f);
    if (!(t[0] & 1))
        return false; // nothing connected to this port
    connected = true;

    auto status = inst.readRegister(no, 0x03);
    status.erase(status.find('\0'));
    if (status != "DBMa") {
        UnlockAce(inst, no, key);
        if (inst.command(no, 'DBMa', std::string("\x01", 1)))
            throw Failure{"Failed to enter debug mode"};
        status = inst.readRegister(no, 0x03);
        status.erase(status.find('\0'));
        if (status != "DBMa")
            throw Failure{"Failed to enter debug mode"};
    }

    if (action == "reboot")
        DoReboot(inst, no);
    else if (action == "dfu")
        DoDFU(inst, no);
    else
        throw Failure{"Unknown action"};

    return true;
}

} // namespace

@implementation VDMTool

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
            throw Failure{"IOServiceMatching failed"};
        io_iterator_t iter = 0;
        if (IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iter) != kIOReturnSuccess)
            throw Failure{"IOServiceGetMatchingServices failed"};

        bool anyConnected = false;
        bool succeeded = false;
        io_service_t device;
        while ((device = IOIteratorNext(iter))) {
            int32_t rid = -1;
            CFNumberRef data = (CFNumberRef)IORegistryEntryCreateCFProperty(
                device, CFSTR("RID"), kCFAllocatorDefault, 0);
            if (data) {
                CFNumberGetValue(data, kCFNumberSInt32Type, &rid);
                CFRelease(data);
            }

            // Try every port that has a device connected, not just RID 0.
            bool connected = false;
            try {
                if (RunOnPort(device, rid, act, key, connected)) {
                    succeeded = true;
                    IOObjectRelease(device);
                    printf("Sent '%s' on port RID %d\n", act.c_str(), rid);
                    break;
                }
            } catch (const Failure &f) {
                // This port had a device but refused — keep trying others.
                fprintf(stderr, "Port RID %d: %s\n", rid, f.message.c_str());
            }
            anyConnected = anyConnected || connected;
            IOObjectRelease(device);
        }
        IOObjectRelease(iter);

        if (succeeded)
            return 0;
        if (!anyConnected) {
            fprintf(stderr, "No USB-C device connected to any port\n");
            return 2;
        }
        fprintf(stderr, "A device was connected but no port accepted the command\n");
        return 3;
    } catch (const Failure &f) {
        fprintf(stderr, "%s\n", f.message.c_str());
        return 1;
    }
}

@end
