import Foundation
import XCTest
@testable import MidiDeck

@MainActor
final class ActionExecutorTests: XCTestCase {
    func testContinuousActionRunsFirstAndNewestValuesWithoutReplayingMiddle() async {
        let source = MIDIEndpointReference(uniqueID: 42, name: "Test Fader")
        let mapping = Mapping(
            description: "Master volume",
            trigger: Trigger(type: .controlChange, channel: 1, controller: 7),
            action: Action(type: .setVolume, device: "default")
        )
        let manager = ConfigManager(
            configurationURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("MidiDeck-ActionExecutorTests-\(UUID().uuidString).json"),
            watchesFile: false
        )
        manager.config = Configuration(
            profiles: ["default": Profile(mappings: [mapping])]
        )

        let firstStarted = expectation(description: "First CoreAudio write started")
        let secondFinished = expectation(description: "Newest CoreAudio write finished")
        let probe = BlockingContinuousActionProbe(
            firstStarted: firstStarted,
            secondFinished: secondFinished
        )
        let executor = ActionExecutor(
            configManager: manager,
            midiOutput: MIDIOutputManager(),
            continuousActionHandler: { action, value in
                probe.handle(action: action, value: value)
            }
        )

        executor.handle(input: input(source: source, value: 10), connectedSources: [source])
        await fulfillment(of: [firstStarted], timeout: 2)

        // These arrive while the simulated CoreAudio call is blocked. Only the
        // newest position should survive as pending work.
        for value: UInt8 in [30, 60, 90, 127] {
            executor.handle(input: input(source: source, value: value), connectedSources: [source])
        }

        probe.releaseFirst()
        await fulfillment(of: [secondFinished], timeout: 2)
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(probe.recordedValues, [10, 127])
        withExtendedLifetime(executor) {}
    }

    private func input(source: MIDIEndpointReference, value: UInt8) -> MIDIInputEvent {
        MIDIInputEvent(
            source: source,
            event: .controlChange(channel: 1, controller: 7, value: value)
        )
    }

}

private final class BlockingContinuousActionProbe: @unchecked Sendable {
    private let firstStarted: XCTestExpectation
    private let secondFinished: XCTestExpectation
    private let releaseSemaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var values: [UInt8] = []

    init(firstStarted: XCTestExpectation, secondFinished: XCTestExpectation) {
        self.firstStarted = firstStarted
        self.secondFinished = secondFinished
    }

    var recordedValues: [UInt8] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }

    func handle(action: Action, value: UInt8) -> ContinuousActionResult {
        lock.lock()
        values.append(value)
        let callNumber = values.count
        lock.unlock()

        if callNumber == 1 {
            firstStarted.fulfill()
            _ = releaseSemaphore.wait(timeout: .now() + 5)
        } else if callNumber == 2 {
            secondFinished.fulfill()
        }

        return ContinuousActionResult(
            succeeded: true,
            detail: "Applied \(action.type.rawValue) \(value)"
        )
    }

    func releaseFirst() {
        releaseSemaphore.signal()
    }
}
