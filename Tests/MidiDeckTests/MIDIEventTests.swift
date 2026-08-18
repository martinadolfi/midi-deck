import XCTest
@testable import MidiDeck

final class MIDIEventTests: XCTestCase {
    func testParsesMIDI1NoteOnAndZeroVelocityNoteOff() {
        let events = MIDIEvent.parse(words: [0x20903C7F, 0x20903C00])
        XCTAssertEqual(events.count, 2)

        guard case .noteOn(let channel, let note, let velocity) = events[0] else {
            return XCTFail("Expected note on")
        }
        XCTAssertEqual(channel, 1)
        XCTAssertEqual(note, 60)
        XCTAssertEqual(velocity, 127)

        guard case .noteOff(let offChannel, let offNote, let offVelocity) = events[1] else {
            return XCTFail("Expected note off")
        }
        XCTAssertEqual(offChannel, 1)
        XCTAssertEqual(offNote, 60)
        XCTAssertEqual(offVelocity, 0)
    }

    func testParsesControlChangeWithOneBasedChannel() {
        let events = MIDIEvent.parse(words: [0x20B90740])
        guard case .controlChange(let channel, let controller, let value) = events.first else {
            return XCTFail("Expected control change")
        }
        XCTAssertEqual(channel, 10)
        XCTAssertEqual(controller, 7)
        XCTAssertEqual(value, 64)
    }

    func testSkipsAllWordsOfUnsupported128BitMessage() {
        let events = MIDIEvent.parse(words: [
            0x50000000, 0x20903C7F, 0x20903D7F, 0x20903E7F,
            0x20903F7F,
        ])

        XCTAssertEqual(events.count, 1)
        guard case .noteOn(_, let note, _) = events[0] else {
            return XCTFail("Expected the message after the 128-bit payload")
        }
        XCTAssertEqual(note, 63)
    }
}
