// Tests/LogicMCPCoreTests/PluginDisplayTests.swift
import XCTest
@testable import LogicMCPCore

final class PluginDisplayTests: XCTestCase {
    func testParsesNumberAndUnit() {
        XCTAssertEqual(PluginDisplay.parse("15 %"),   .init(number: 15,   unit: "%",  raw: "15 %"))
        XCTAssertEqual(PluginDisplay.parse("0.0 dB"), .init(number: 0,    unit: "dB", raw: "0.0 dB"))
        XCTAssertEqual(PluginDisplay.parse("0.18 Hz"),.init(number: 0.18, unit: "Hz", raw: "0.18 Hz"))
        XCTAssertEqual(PluginDisplay.parse("-6 dB"),  .init(number: -6,   unit: "dB", raw: "-6 dB"))
        XCTAssertEqual(PluginDisplay.parse("0 ms"),   .init(number: 0,    unit: "ms", raw: "0 ms"))
    }
    func testBareNumberHasEmptyUnit() {
        XCTAssertEqual(PluginDisplay.parse("1.00"), .init(number: 1.0, unit: "", raw: "1.00"))
        XCTAssertEqual(PluginDisplay.parse("100L"), .init(number: 100, unit: "L", raw: "100L"))
    }
    func testEnumTextHasNoNumber() {
        XCTAssertEqual(PluginDisplay.parse("Mono"), .init(number: nil, unit: nil, raw: "Mono"))
        XCTAssertEqual(PluginDisplay.parse("Off"),  .init(number: nil, unit: nil, raw: "Off"))
        XCTAssertEqual(PluginDisplay.parse("1/4"),  .init(number: nil, unit: nil, raw: "1/4"))
    }
}
