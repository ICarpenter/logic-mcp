import XCTest
@testable import LogicMCPCore

final class MCUCodecTests: XCTestCase {
    func testFaderMoveEncodesAsPitchBend() {
        XCTAssertEqual(MCUCodec.encode(MCUCommand.faderMove(channel: 0, value: 8192)),
                       [0xE0, 0x00, 0x40])
        XCTAssertEqual(MCUCodec.encode(MCUCommand.faderMove(channel: 7, value: 16383)),
                       [0xE7, 0x7F, 0x7F])
    }

    func testFaderEchoDecodes() {
        guard case .faderEcho(let ch, let v)? = MCUCodec.decodeEvent([0xE2, 0x10, 0x20]) else {
            return XCTFail("expected faderEcho")
        }
        XCTAssertEqual(ch, 2)
        XCTAssertEqual(v, (0x20 << 7) | 0x10)  // 4112
    }

    func testLCDSysExDecodes() {
        var bytes: [UInt8] = [0xF0, 0x00, 0x00, 0x66, 0x14, 0x12, 56]
        bytes += Array("Vocal  ".utf8)
        bytes.append(0xF7)
        guard case .lcd(let offset, let text)? = MCUCodec.decodeEvent(bytes) else {
            return XCTFail("expected lcd")
        }
        XCTAssertEqual(offset, 56)
        XCTAssertEqual(text, "Vocal  ")
    }

    func testButtonRoundTrip() {
        XCTAssertEqual(MCUCodec.encode(MCUCommand.buttonPress(.play)), [0x90, 0x5E, 0x7F])
        XCTAssertEqual(MCUCodec.encode(MCUCommand.buttonRelease(.mute(channel: 3))), [0x90, 0x13, 0x00])
        guard case .buttonPress(let b)? = MCUCodec.decodeCommand([0x90, 0x2E, 0x7F]) else {
            return XCTFail("expected press")
        }
        XCTAssertEqual(b, .bankLeft)
    }

    func testLEDDecodes() {
        guard case .led(let b, let s)? = MCUCodec.decodeEvent([0x90, 0x10, 0x7F]) else {
            return XCTFail("expected led")
        }
        XCTAssertEqual(b, .mute(channel: 0))
        XCTAssertEqual(s, .on)
        guard case .led(_, let blink)? = MCUCodec.decodeEvent([0x90, 0x5E, 0x01]) else {
            return XCTFail("expected led")
        }
        XCTAssertEqual(blink, .blink)
    }

    func testVPotTurnEncodesDelta() {
        XCTAssertEqual(MCUCodec.encode(MCUCommand.vpotTurn(channel: 0, ticks: 3)), [0xB0, 0x10, 0x03])
        XCTAssertEqual(MCUCodec.encode(MCUCommand.vpotTurn(channel: 5, ticks: -2)), [0xB0, 0x15, 0x42])
    }

    func testHandshakeDecode() {
        XCTAssertNotNil(MCUCodec.decodeEvent([0xF0, 0x00, 0x00, 0x66, 0x14, 0x00, 0xF7]))
        guard case .deviceQuery? = MCUCodec.decodeEvent([0xF0, 0x00, 0x00, 0x66, 0x14, 0x00, 0xF7]) else {
            return XCTFail("expected deviceQuery")
        }
    }

    func testTimecodeDigitDecodes() {
        // 0xB0 0x40 0x30 → rightmost digit '0'
        guard case .timecodeDigit(let idx, let ch)? = MCUCodec.decodeEvent([0xB0, 0x40, 0x30]) else {
            return XCTFail("expected timecodeDigit")
        }
        XCTAssertEqual(idx, 0)
        XCTAssertEqual(ch, "0")
    }

    func testMeterDecodes() {
        guard case .meter(let ch, let lvl)? = MCUCodec.decodeEvent([0xD0, 0x3C]) else {
            return XCTFail("expected meter")
        }
        XCTAssertEqual(ch, 3)
        XCTAssertEqual(lvl, 12)
    }
}
