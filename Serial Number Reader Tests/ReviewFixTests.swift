import Foundation
import JTKit
import JTKitTestSupport
import Testing
@testable import Serial_Number_Reader

/// The 1.5.0 review's fixes: the Device menu while a sheet is open or the
/// asset tag is edited, the selection after a row is removed, and the
/// notice when the one-time conversion couldn't read the Keychain.
@MainActor
@Suite("Review fixes")
struct ReviewFixTests {
    private let configurator = ConfiguratorDevice(ecid: "0x1A2B3C4D5E6F70", udid: "00008140-001A2B3C4D5E6F70",
                                                  deviceType: "iPhone17,3", locationID: 0x0130_0000)

    private func recovery(connected: Bool = true) -> USBDevice {
        USBDevice(id: 1, mode: .recovery, productID: 0x1281, usbProductName: nil,
                  descriptor: DescriptorParser.parse("CPID:8140 BDID:08 ECID:001A2B3C4D5E6F70 SRNM:[PLACEHOLDR41]"),
                  udid: nil, modelInfo: ModelDatabase.shared.model(identifier: "iPhone17,3"), configurator: configurator,
                  connectedAt: .now, isConnected: connected)
    }

    private func availability(_ device: USBDevice, busy: Bool = false, editing: Bool = false) -> DeviceActionAvailability {
        DeviceActionAvailability(device: device, busy: busy, editingAssetTag: editing, connectedDeviceCount: 1,
                                 configuratorAvailable: true, jamfState: .noMatch)
    }

    // MARK: Finding 4: the Device menu behind the Restore or Revive sheet

    @Test("With the Restore or Revive sheet open (busy for the menu), no device action is offered in the Device menu")
    func sheetOpenDimsDeviceMenu() {
        let free = availability(recovery())
        #expect(free.bootToNormal && free.restart && free.enterDFU && free.restore)

        let behindSheet = availability(recovery(), busy: true)
        #expect(!behindSheet.enterRecovery && !behindSheet.bootToNormal && !behindSheet.restart)
        #expect(!behindSheet.enterDFU && !behindSheet.restore && !behindSheet.removeTrust)
    }

    // MARK: Finding 5: ⌘⌫ while the asset tag is typed

    @Test("Remove from List is off while the asset tag is being edited, on again after")
    func editingAssetTagBlocksRemoval() {
        let disconnected = recovery(connected: false)
        #expect(availability(disconnected).removeFromList)
        #expect(!availability(disconnected, editing: true).removeFromList)
        #expect(!availability(recovery()).removeFromList, "A connected device is never removed")
    }

    // MARK: Finding 6: the selection after a removal

    @Test("Removing the selected row selects its neighbor, never the newest device")
    func removalSelectsNeighbor() {
        // Newest first, as the list shows them.
        let rows: [USBDevice.ID] = [30, 20, 10]
        #expect(DeviceSelection.next(selected: 20, old: rows, new: [30, 10]) == 10, "the next older row")
        #expect(DeviceSelection.next(selected: 10, old: rows, new: [30, 20]) == 20, "the oldest gone: the one above")
        #expect(DeviceSelection.next(selected: 30, old: rows, new: [20, 10]) == 20)
        #expect(DeviceSelection.next(selected: 10, old: [10], new: []) == nil, "the last row: nothing")
        // Clear Disconnected with the selection among them: the remaining neighbor.
        #expect(DeviceSelection.next(selected: 20, old: rows, new: [30]) == 30)
    }

    @Test("The selection stays, follows a device that came back, and picks a new device when nothing is selected")
    func otherSelectionChanges() {
        #expect(DeviceSelection.next(selected: 20, old: [30, 20, 10], new: [40, 30, 20, 10]) == 20, "a new device doesn't take over")
        #expect(DeviceSelection.next(selected: 20, old: [20, 10], new: [40, 10]) == 40, "the device rebooted and replaced its row")
        #expect(DeviceSelection.next(selected: nil, old: [20], new: [40, 20]) == 40, "nothing selected: the device that connected")
        #expect(DeviceSelection.next(selected: nil, old: [30, 20], new: [30, 20]) == 30, "at launch: the newest")
        #expect(DeviceSelection.next(selected: nil, old: [30, 20], new: [20]) == nil)
    }

    // MARK: The action buttons in a narrow window

    @Test("The action buttons wrap onto a new line instead of being cut off")
    func actionButtonsWrap() {
        let widths: [CGFloat] = [130, 80, 100, 90, 85]
        #expect(WrappingHStack.lines(widths: widths, available: 1000, spacing: 10) == [[0, 1, 2, 3, 4]])
        #expect(WrappingHStack.lines(widths: widths, available: 330, spacing: 10) == [[0, 1, 2], [3, 4]])
        #expect(WrappingHStack.lines(widths: widths, available: 100, spacing: 10) == [[0], [1], [2], [3], [4]],
                "a button wider than the line gets a line of its own")
        #expect(WrappingHStack.lines(widths: [], available: 100, spacing: 10).isEmpty)
    }

    // MARK: Finding 7: the conversion waits for the Keychain, and says so

    @Test("When the Keychain refuses an old secret, Settings › Connections gets a notice; none once converted")
    func conversionProblemIsShown() throws {
        let settings = TemporaryDefaults("review-conversion")
        defer { settings.remove() }
        let secrets = InMemorySecretStore(["clientSecret": "pro-secret"])
        settings.defaults.set("https://pro.example.com", forKey: LegacySettingsConversion.OldKey.serverURL)
        settings.defaults.set("client", forKey: LegacySettingsConversion.OldKey.clientID)
        secrets.refusesReads = true

        let refused = AppConnectionStore(defaults: settings.defaults, secrets: secrets)
        let notice = try #require(refused.conversionProblem)
        #expect(notice.contains("weren’t converted"))
        #expect(notice.contains("Keychain"))
        #expect(notice.contains("tries again"))
        #expect(refused.connections.records.isEmpty)

        secrets.refusesReads = false
        let next = AppConnectionStore(defaults: settings.defaults, secrets: secrets)
        #expect(next.conversionProblem == nil)
        #expect(next.connections.records.count == 1)
    }
}
