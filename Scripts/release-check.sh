#!/bin/zsh
# Serial Number Reader's release check. Claude runs it
# unattended with nohup; the report lands in
# ~/Library/Application Support/JTKit Release Check/runs/.
#   Scripts/release-check.sh [--local-jtkit] [--tenants] [--include-production] [--stop-before-live]
#   Scripts/release-check.sh --local-jtkit --fault break-build|fail-live-step|interrupt-live|usb-attempt
# Tenants are roles on the local allow-list (never named here): jamfpro-readonly
# (Jamf Pro over the Platform API) and jamfschool-readonly, read only;
# jamf-test-a over the Platform API (one JTKTEST mobile device record, removed
# afterwards); jamfpro-production, read only, only with --include-production.
# No USB action ever runs: under tests the app refuses them all, and any
# attempt fails the run.
cd "$(dirname "$0")/.." || exit 1

APP_NAME="Serial Number Reader"
APP_CODE="SN"
PROJECT="Serial Number Reader.xcodeproj"
SCHEME="Serial Number Reader Release Check"
UNIT_TESTS="Serial Number Reader Tests"
UI_TESTS="Serial Number Reader UITests"
SMOKE_CLASS="DemoSmokeUITests"
SMOKE_FILE="$PWD/Serial Number Reader UITests/DemoSmokeUITests.swift"
SIGNIN_TEST="Serial Number Reader Tests/LiveSignInTests"
LIVE_TESTS=("Serial Number Reader Tests/LiveLookupTests/readOnlyLookups()"
            "Serial Number Reader Tests/LiveLookupTests/assetTag()")
CLEANUP_TEST="Serial Number Reader Tests/LiveCleanupTests"
ROLES=(jamfpro-readonly jamfschool-readonly jamf-test-a jamfpro-production)
# role:service:item, read from the Keychain service the allow-list names.
# jamfpro-production's are read only with --include-production.
CREDENTIALS=("jamfpro-readonly:jamfPlatform:client-id" "jamfpro-readonly:jamfPlatform:client-secret"
             "jamfschool-readonly:jamfSchool:network-id" "jamfschool-readonly:jamfSchool:api-key"
             "jamf-test-a:jamfPlatform:client-id" "jamf-test-a:jamfPlatform:client-secret"
             "jamfpro-production:jamfPlatform:client-id" "jamfpro-production:jamfPlatform:client-secret")
APP_FAULTS=(usb-attempt)
DOMAIN="be.jordythery.serialnumberreader"
# Saved connections and the one in use, the demo switch, the conversion flag
# and the settings of versions before connections (only ever read).
FINGERPRINT_DEFAULTS=()
for key in jamfConnections jamfConnections.backup activeJamfConnectionID demoMode jamfConnectionsConverted \
           jamfAuthMethod jamfServerURL jamfClientID jamfUsername jamfPlatformRegion jamfPlatformClientID \
           jamfPlatformEnvironmentID jamfSchoolURL jamfSchoolNetworkID; do
    FINGERPRINT_DEFAULTS+=("$DOMAIN $key")
done
# The activity log lives in memory only: these are where it would appear if
# it were ever written to disk. They must stay absent.
FINGERPRINT_PATHS=("$HOME/Library/Application Support/Serial Number Reader"
                   "$HOME/Library/Application Support/$DOMAIN"
                   "$HOME/Library/Logs/Serial Number Reader"
                   "$HOME/Library/Logs/$DOMAIN")
KEYCHAIN_PREFIXES=("be.jordythery.SerialNumberReader.jamf")

# --fault usb-attempt sends one Restart through the app's real doorway (the
# guard refuses it). Restart targets the first port with a device, so this
# fault starts only when no Apple device is connected over USB.
if [[ " $* " == *" --fault usb-attempt "* ]]; then
    connected="$(/usr/sbin/ioreg -r -c IOUSBHostDevice -l -w0 | /usr/bin/python3 -c '
import re, sys
devices, current = [], {}
for line in sys.stdin:
    if line.lstrip().startswith("+-o"):
        if current: devices.append(current)
        current = {"name": line.split("+-o", 1)[1].split("<")[0].strip()}
    for key in ("idVendor", "idProduct"):
        m = re.search(r"\"%s\" = (\d+)" % key, line)
        if m: current[key] = int(m.group(1))
if current: devices.append(current)
# iPhone, iPad and Mac targets: Normal 0x1290-0x12AF, Recovery 0x1280-0x1283,
# DFU 0x1220-0x1227 and "Debug USB" 0x1881 (Apple vendor 0x05AC).
def target(p): return 0x1290 <= p <= 0x12AF or 0x1280 <= p <= 0x1283 or 0x1220 <= p <= 0x1227 or p == 0x1881
print("\n".join("%s (0x%04X)" % (d["name"], d["idProduct"]) for d in devices
                if d.get("idVendor") == 0x05AC and target(d.get("idProduct", -1))))
')" || { print -u2 "Couldn't list USB devices with ioreg; --fault usb-attempt doesn't start."; exit 2 }
    if [[ -n "$connected" ]]; then
        print -u2 "--fault usb-attempt refused: an Apple device is connected over USB, and Restart targets the first port with a device."
        print -u2 "Unplug it and start again. Connected:"
        print -u2 -- "$connected"
        exit 2
    fi
fi

# Each run starts with no recorded attempts (USB, saved connections).
rm -rf "$(getconf DARWIN_USER_TEMP_DIR)SerialNumberReader-under-test"

if [[ " $* " == *" --local-jtkit "* ]]; then
    LIB="${JTKIT_LOCAL:-$HOME/Developer/JTKit}/Scripts/release-check-lib.sh"
else
    PACKAGES="$HOME/Library/Developer/Xcode/DerivedData/JTKitReleaseCheck-$APP_CODE/SourcePackages"
    xcodebuild -resolvePackageDependencies -project "$PROJECT" -scheme "$SCHEME" \
        -clonedSourcePackagesDirPath "$PACKAGES" > /dev/null || exit 1
    LIB="$PACKAGES/checkouts/JTKit/Scripts/release-check-lib.sh"
fi
[[ -f "$LIB" ]] || { print -u2 "No release-check template at $LIB (JTKit 0.12.3 or later)"; exit 1 }
source "$LIB"
release_check_main "$@"
