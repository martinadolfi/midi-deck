import XCTest
@testable import MidiDeck

final class MIDIOutputManagerTests: XCTestCase {
    func testImplicitResolutionRequiresExactlyOneDestination() {
        let first = endpoint(1, "First")
        let second = endpoint(2, "Second")

        XCTAssertEqual(
            resolve(.implicit, among: []),
            .unavailable(.noDestinations)
        )
        XCTAssertEqual(
            resolve(.implicit, among: [first]),
            .resolved(index: 0)
        )
        XCTAssertEqual(
            resolve(.implicit, among: [first, second]),
            .unavailable(.implicitRequiresSelection(destinationCount: 2))
        )
    }

    func testExplicitDestinationMatchesStableIDAfterRename() {
        let persisted = endpoint(42, "Old Display Name")
        let destinations = [
            endpoint(7, "Other"),
            endpoint(42, "Renamed Controller"),
        ]

        XCTAssertEqual(
            resolve(.endpoint(persisted), among: destinations),
            .resolved(index: 1)
        )
    }

    func testMissingExplicitDestinationFailsClosed() {
        let requested = endpoint(99, "Disconnected Controller")

        XCTAssertEqual(
            resolve(.endpoint(requested), among: [endpoint(1, "Connected Controller")]),
            .unavailable(
                .endpointNotConnected(
                    name: "Disconnected Controller",
                    uniqueID: 99
                )
            )
        )
    }

    func testDuplicateStableIDsFailClosed() {
        let requested = endpoint(42, "Persisted Name")

        XCTAssertEqual(
            resolve(
                .endpoint(requested),
                among: [endpoint(42, "First"), endpoint(42, "Second")]
            ),
            .unavailable(.endpointAmbiguous(uniqueID: 42))
        )
    }

    func testAmbiguousLegacyExactNamesFailClosed() {
        let destinations = [endpoint(1, "iRig"), endpoint(2, "IRIG")]

        XCTAssertEqual(
            resolve(.legacyName("irig"), among: destinations),
            .unavailable(.legacyNameAmbiguous("irig"))
        )
    }

    func testAmbiguousLegacyPartialNamesFailClosed() {
        let destinations = [
            endpoint(1, "Launchpad Mini"),
            endpoint(2, "Launchpad Pro"),
        ]

        XCTAssertEqual(
            resolve(.legacyName("Launchpad"), among: destinations),
            .unavailable(.legacyNameAmbiguous("Launchpad"))
        )
    }

    func testUniqueLegacyExactAndPartialNamesResolve() {
        let destinations = [endpoint(1, "iRig Keys"), endpoint(2, "Launchpad")]

        XCTAssertEqual(
            resolve(.legacyName("launchpad"), among: destinations),
            .resolved(index: 1)
        )
        XCTAssertEqual(
            resolve(.legacyName("irig"), among: destinations),
            .resolved(index: 0)
        )
    }

    private func resolve(
        _ selector: MIDIOutputManager.DestinationSelector,
        among destinations: [MIDIEndpointReference]
    ) -> MIDIOutputManager.DestinationResolution {
        MIDIOutputManager.resolveDestination(for: selector, among: destinations)
    }

    private func endpoint(_ uniqueID: Int32, _ name: String) -> MIDIEndpointReference {
        MIDIEndpointReference(uniqueID: uniqueID, name: name)
    }
}
