import XCTest
@testable import MidiDeck

final class MIDIEngineTests: XCTestCase {
    func testEventsAreMulticastToIndependentSubscribers() async {
        let engine = MIDIEngine()
        var firstSubscriber = engine.events().makeAsyncIterator()
        var secondSubscriber = engine.events().makeAsyncIterator()
        let source = MIDIEndpointReference(uniqueID: 42, name: "Test Controller")
        let input = MIDIInputEvent(
            source: source,
            event: .noteOn(channel: 2, note: 60, velocity: 100)
        )

        engine.publish(input)

        let firstEvent = await firstSubscriber.next()
        let secondEvent = await secondSubscriber.next()
        assertNoteOn(firstEvent, source: source, channel: 2, note: 60, velocity: 100)
        assertNoteOn(secondEvent, source: source, channel: 2, note: 60, velocity: 100)
    }

    func testCancellingOneSubscriberDoesNotFinishAnother() async {
        let engine = MIDIEngine()
        let cancelledStream = engine.events()
        var survivingSubscriber = engine.events().makeAsyncIterator()
        let cancelledRead = Task {
            var iterator = cancelledStream.makeAsyncIterator()
            return await iterator.next()
        }

        await Task.yield()
        cancelledRead.cancel()
        let cancelledEvent = await cancelledRead.value
        XCTAssertNil(cancelledEvent)

        let source = MIDIEndpointReference(uniqueID: 7, name: "Surviving Controller")
        engine.publish(
            MIDIInputEvent(
                source: source,
                event: .noteOn(channel: 1, note: 36, velocity: 127)
            )
        )

        let survivingEvent = await survivingSubscriber.next()
        assertNoteOn(survivingEvent, source: source, channel: 1, note: 36, velocity: 127)
    }

    private func assertNoteOn(
        _ input: MIDIInputEvent?,
        source: MIDIEndpointReference,
        channel: UInt8,
        note: UInt8,
        velocity: UInt8,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let input else {
            return XCTFail("Expected an input event", file: file, line: line)
        }
        XCTAssertEqual(input.source.uniqueID, source.uniqueID, file: file, line: line)
        XCTAssertEqual(input.source.name, source.name, file: file, line: line)
        guard case .noteOn(
            let actualChannel,
            let actualNote,
            let actualVelocity
        ) = input.event else {
            return XCTFail("Expected note on", file: file, line: line)
        }
        XCTAssertEqual(actualChannel, channel, file: file, line: line)
        XCTAssertEqual(actualNote, note, file: file, line: line)
        XCTAssertEqual(actualVelocity, velocity, file: file, line: line)
    }
}
