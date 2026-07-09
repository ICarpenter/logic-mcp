/// Mackie Control button ↔ note-number map (Logic Control MIDI implementation).
public enum MCUButton: Equatable, Hashable, Sendable {
    case recArm(channel: Int)      // 0x00 + ch
    case solo(channel: Int)        // 0x08 + ch
    case mute(channel: Int)        // 0x10 + ch
    case select(channel: Int)      // 0x18 + ch
    case vpotPress(channel: Int)   // 0x20 + ch
    case assignTrack, assignSend, assignPan, assignPlugin, assignEQ, assignInstrument // 0x28–0x2D
    case bankLeft, bankRight, channelLeft, channelRight                                // 0x2E–0x31
    case flip, global, nameValue, smpteBeats                                           // 0x32–0x35
    case function(Int)             // F1–F8 → 0x36 + (n-1)
    case automationRead, automationWrite, automationTrim, automationTouch, automationLatch // 0x4A–0x4E
    case save, undo, cancel, enter                                                     // 0x50–0x53
    case marker, nudge, cycle, drop, replace, click, globalSolo                        // 0x54–0x5A
    case rewind, fastForward, stop, play, record                                       // 0x5B–0x5F
    case cursorUp, cursorDown, cursorLeft, cursorRight, zoom, scrub                    // 0x60–0x65

    public var note: UInt8 {
        switch self {
        case .recArm(let c): return UInt8(0x00 + c)
        case .solo(let c): return UInt8(0x08 + c)
        case .mute(let c): return UInt8(0x10 + c)
        case .select(let c): return UInt8(0x18 + c)
        case .vpotPress(let c): return UInt8(0x20 + c)
        case .assignTrack: return 0x28
        case .assignSend: return 0x29
        case .assignPan: return 0x2A
        case .assignPlugin: return 0x2B
        case .assignEQ: return 0x2C
        case .assignInstrument: return 0x2D
        case .bankLeft: return 0x2E
        case .bankRight: return 0x2F
        case .channelLeft: return 0x30
        case .channelRight: return 0x31
        case .flip: return 0x32
        case .global: return 0x33
        case .nameValue: return 0x34
        case .smpteBeats: return 0x35
        case .function(let n): return UInt8(0x36 + (n - 1))
        case .automationRead: return 0x4A
        case .automationWrite: return 0x4B
        case .automationTrim: return 0x4C
        case .automationTouch: return 0x4D
        case .automationLatch: return 0x4E
        case .save: return 0x50
        case .undo: return 0x51
        case .cancel: return 0x52
        case .enter: return 0x53
        case .marker: return 0x54
        case .nudge: return 0x55
        case .cycle: return 0x56
        case .drop: return 0x57
        case .replace: return 0x58
        case .click: return 0x59
        case .globalSolo: return 0x5A
        case .rewind: return 0x5B
        case .fastForward: return 0x5C
        case .stop: return 0x5D
        case .play: return 0x5E
        case .record: return 0x5F
        case .cursorUp: return 0x60
        case .cursorDown: return 0x61
        case .cursorLeft: return 0x62
        case .cursorRight: return 0x63
        case .zoom: return 0x64
        case .scrub: return 0x65
        }
    }

    public init?(note: UInt8) {
        switch note {
        case 0x00...0x07: self = .recArm(channel: Int(note))
        case 0x08...0x0F: self = .solo(channel: Int(note) - 0x08)
        case 0x10...0x17: self = .mute(channel: Int(note) - 0x10)
        case 0x18...0x1F: self = .select(channel: Int(note) - 0x18)
        case 0x20...0x27: self = .vpotPress(channel: Int(note) - 0x20)
        case 0x28: self = .assignTrack
        case 0x29: self = .assignSend
        case 0x2A: self = .assignPan
        case 0x2B: self = .assignPlugin
        case 0x2C: self = .assignEQ
        case 0x2D: self = .assignInstrument
        case 0x2E: self = .bankLeft
        case 0x2F: self = .bankRight
        case 0x30: self = .channelLeft
        case 0x31: self = .channelRight
        case 0x32: self = .flip
        case 0x33: self = .global
        case 0x34: self = .nameValue
        case 0x35: self = .smpteBeats
        case 0x36...0x3D: self = .function(Int(note) - 0x36 + 1)
        case 0x4A: self = .automationRead
        case 0x4B: self = .automationWrite
        case 0x4C: self = .automationTrim
        case 0x4D: self = .automationTouch
        case 0x4E: self = .automationLatch
        case 0x50: self = .save
        case 0x51: self = .undo
        case 0x52: self = .cancel
        case 0x53: self = .enter
        case 0x54: self = .marker
        case 0x55: self = .nudge
        case 0x56: self = .cycle
        case 0x57: self = .drop
        case 0x58: self = .replace
        case 0x59: self = .click
        case 0x5A: self = .globalSolo
        case 0x5B: self = .rewind
        case 0x5C: self = .fastForward
        case 0x5D: self = .stop
        case 0x5E: self = .play
        case 0x5F: self = .record
        case 0x60: self = .cursorUp
        case 0x61: self = .cursorDown
        case 0x62: self = .cursorLeft
        case 0x63: self = .cursorRight
        case 0x64: self = .zoom
        case 0x65: self = .scrub
        default: return nil
        }
    }
}
