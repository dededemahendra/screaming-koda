import Testing
@testable import KodaCore

@Test func versionStringIsSet() {
    #expect(KodaCoreInfo.versionString == "0.1.0")
}
