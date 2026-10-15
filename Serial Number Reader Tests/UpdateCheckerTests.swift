import Testing
@testable import Serial_Number_Reader

@Suite("Update version comparison")
struct UpdateCheckerTests {

    @Test("Newer minor and patch versions are detected")
    func newer() {
        #expect(UpdateChecker.isNewer("1.2", than: "1.1"))
        #expect(UpdateChecker.isNewer("1.1.1", than: "1.1"))
        #expect(UpdateChecker.isNewer("2.0", than: "1.9.9"))
    }

    @Test("Components compare numerically, not as text")
    func numeric() {
        #expect(UpdateChecker.isNewer("1.10", than: "1.9"))
        #expect(!UpdateChecker.isNewer("1.9", than: "1.10"))
    }

    @Test("Equal or older versions are not offered")
    func notNewer() {
        #expect(!UpdateChecker.isNewer("1.1", than: "1.1"))
        #expect(!UpdateChecker.isNewer("1.1.0", than: "1.1"))
        #expect(!UpdateChecker.isNewer("1.0", than: "1.1"))
    }
}
