public enum LEDState: Equatable, Sendable { case off, on, blink }

public enum MCUCommand: Equatable, Sendable {
    case faderMove(channel: Int, value: Int)      // value 0...16383
    case faderTouch(channel: Int, touched: Bool)
    case buttonPress(MCUButton)
    case buttonRelease(MCUButton)
    case vpotTurn(channel: Int, ticks: Int)       // ticks -7...-1, 1...7
    case hostConnectionQuery(serial: [UInt8], challenge: [UInt8])
    case connectionConfirmation(serial: [UInt8])
}

public enum MCUEvent: Equatable, Sendable {
    case faderEcho(channel: Int, value: Int)
    case lcd(offset: Int, text: String)
    case led(button: MCUButton, state: LEDState)
    case vpotRing(channel: Int, value: Int)
    case timecodeDigit(index: Int, char: Character)
    case meter(channel: Int, level: Int)
    case deviceQuery
    case hostConnectionReply(serial: [UInt8])
}

public enum MCUCodec {
    static let sysExHeader: [UInt8] = [0xF0, 0x00, 0x00, 0x66, 0x14]

    // MARK: surface → Logic

    public static func encode(_ command: MCUCommand) -> [UInt8] {
        switch command {
        case .faderMove(let ch, let v):
            let clamped = max(0, min(16383, v))
            return [0xE0 | UInt8(ch), UInt8(clamped & 0x7F), UInt8((clamped >> 7) & 0x7F)]
        case .faderTouch(let ch, let touched):
            let note: UInt8 = ch == 8 ? 0x70 : 0x68 + UInt8(ch)
            return [0x90, note, touched ? 0x7F : 0x00]
        case .buttonPress(let b):
            return [0x90, b.note, 0x7F]
        case .buttonRelease(let b):
            return [0x90, b.note, 0x00]
        case .vpotTurn(let ch, let ticks):
            let magnitude = UInt8(min(7, abs(ticks)))
            let value = ticks >= 0 ? magnitude : 0x40 | magnitude
            return [0xB0, 0x10 + UInt8(ch), value]
        case .hostConnectionQuery(let serial, let challenge):
            return sysExHeader + [0x01] + serial + challenge + [0xF7]
        case .connectionConfirmation(let serial):
            return sysExHeader + [0x03] + serial + [0xF7]
        }
    }

    // MARK: Logic → surface (used by FakeLogic and the capture tool)

    public static func encode(_ event: MCUEvent) -> [UInt8] {
        switch event {
        case .faderEcho(let ch, let v):
            let clamped = max(0, min(16383, v))
            return [0xE0 | UInt8(ch), UInt8(clamped & 0x7F), UInt8((clamped >> 7) & 0x7F)]
        case .lcd(let offset, let text):
            return sysExHeader + [0x12, UInt8(offset)] + Array(text.utf8) + [0xF7]
        case .led(let button, let state):
            let velocity: UInt8 = switch state { case .off: 0x00; case .blink: 0x01; case .on: 0x7F }
            return [0x90, button.note, velocity]
        case .vpotRing(let ch, let v):
            return [0xB0, 0x30 + UInt8(ch), UInt8(v & 0x7F)]
        case .timecodeDigit(let index, let char):
            let ascii = char.asciiValue ?? 0x20
            let code: UInt8 = ascii >= 0x40 ? ascii - 0x40 : ascii
            return [0xB0, 0x40 + UInt8(index), code & 0x3F]
        case .meter(let ch, let level):
            return [0xD0, UInt8((ch << 4) | (level & 0x0F))]
        case .deviceQuery:
            return sysExHeader + [0x00, 0xF7]
        case .hostConnectionReply(let serial):
            return sysExHeader + [0x02] + serial + [0xF7]
        }
    }

    // MARK: decoding

    public static func decodeEvent(_ bytes: [UInt8]) -> MCUEvent? {
        guard let first = bytes.first else { return nil }
        switch first & 0xF0 {
        case 0xE0:
            guard bytes.count == 3 else { return nil }
            return .faderEcho(channel: Int(first & 0x0F), value: Int(bytes[2]) << 7 | Int(bytes[1]))
        case 0x90:
            guard bytes.count == 3, let button = MCUButton(note: bytes[1]) else { return nil }
            let state: LEDState = bytes[2] == 0x00 ? .off : (bytes[2] == 0x7F ? .on : .blink)
            return .led(button: button, state: state)
        case 0xB0:
            guard bytes.count == 3 else { return nil }
            switch bytes[1] {
            case 0x30...0x37:
                return .vpotRing(channel: Int(bytes[1]) - 0x30, value: Int(bytes[2]))
            case 0x40...0x49:
                let low6 = bytes[2] & 0x3F
                let ascii = low6 < 0x20 ? low6 + 0x40 : low6
                return .timecodeDigit(index: Int(bytes[1]) - 0x40,
                                      char: Character(UnicodeScalar(ascii)))
            default:
                return nil
            }
        case 0xD0:
            guard bytes.count == 2 else { return nil }
            return .meter(channel: Int(bytes[1] >> 4), level: Int(bytes[1] & 0x0F))
        case 0xF0:
            guard bytes.count >= 7, Array(bytes.prefix(5)) == sysExHeader, bytes.last == 0xF7 else { return nil }
            let body = Array(bytes[5..<(bytes.count - 1)])
            switch body.first {
            case 0x00:
                return .deviceQuery
            case 0x02:
                return .hostConnectionReply(serial: Array(body.dropFirst().prefix(7)))
            case 0x12:
                guard body.count >= 2 else { return nil }
                let text = String(bytes: body.dropFirst(2), encoding: .ascii) ?? ""
                return .lcd(offset: Int(body[1]), text: text)
            default:
                return nil
            }
        default:
            return nil
        }
    }

    public static func decodeCommand(_ bytes: [UInt8]) -> MCUCommand? {
        guard let first = bytes.first else { return nil }
        switch first & 0xF0 {
        case 0xE0:
            guard bytes.count == 3 else { return nil }
            return .faderMove(channel: Int(first & 0x0F), value: Int(bytes[2]) << 7 | Int(bytes[1]))
        case 0x90:
            guard bytes.count == 3 else { return nil }
            if (0x68...0x70).contains(bytes[1]) {
                let ch = bytes[1] == 0x70 ? 8 : Int(bytes[1]) - 0x68
                return .faderTouch(channel: ch, touched: bytes[2] != 0)
            }
            guard let button = MCUButton(note: bytes[1]) else { return nil }
            return bytes[2] == 0 ? .buttonRelease(button) : .buttonPress(button)
        case 0xB0:
            guard bytes.count == 3, (0x10...0x17).contains(bytes[1]) else { return nil }
            let magnitude = Int(bytes[2] & 0x07)
            let ticks = (bytes[2] & 0x40) != 0 ? -magnitude : magnitude
            return .vpotTurn(channel: Int(bytes[1]) - 0x10, ticks: ticks)
        case 0xF0:
            guard bytes.count >= 7, Array(bytes.prefix(5)) == sysExHeader, bytes.last == 0xF7 else { return nil }
            let body = Array(bytes[5..<(bytes.count - 1)])
            switch body.first {
            case 0x01:
                let payload = Array(body.dropFirst())
                return .hostConnectionQuery(serial: Array(payload.prefix(7)),
                                            challenge: Array(payload.dropFirst(7).prefix(4)))
            case 0x03:
                return .connectionConfirmation(serial: Array(body.dropFirst().prefix(7)))
            default:
                return nil
            }
        default:
            return nil
        }
    }
}
