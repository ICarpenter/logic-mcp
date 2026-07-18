import XCTest
@testable import LogicMCPCore

final class AXConvergerTests: XCTestCase {
    /// A bare AXBridge over one settable slider whose sibling AXGroup display follows the raw via
    /// `map`. `stepMode==false` → absolute setNumber (binary-search path); `true` → increment/
    /// decrement steps (step path). Returns the bridge, the slider handle, and the display handle.
    private func makeSliderBridge(min: Double, max: Double, start: Double,
                                  stepMode: Bool, map: @escaping (Double) -> String)
        async throws -> (AXBridge, AXHandle, AXHandle) {
        let slider = FakeAXNode(role: "AXSlider", value: start, settable: true, minValue: min, maxValue: max)
        let group = FakeAXNode(role: "AXGroup", stringValue: map(start))
        let root = FakeAXNode(role: "AXApplication", children: [group, slider])
        let p = FakeAXProvider(root: root)
        p.nudgeMode = false                       // absolute sets; step path uses inc/dec, unaffected
        p.onSetNumber = { n, raw in if n === slider { group.stringValue = map(raw) } }
        let bridge = AXBridge(provider: p)
        // Resolve handles by walking the bridge's provider view.
        let handles = await bridge.childHandlesForTest(of: bridge.rootForTest())
        return (bridge, handles.slider, handles.display)
    }

    func testBinarySearchConvergesUp() async throws {
        let (bridge, s, d) = try await makeSliderBridge(min: 0, max: 480, start: 0, stepMode: false) {
            "\(($0 - 240) / 10) dB"                // dB = (raw-240)/10  → raw 210 = -3 dB
        }
        let got = try await bridge.convergeAdaptive(slider: s, display: d, target: -3,
                                                    tolerance: 0.5, actuation: .absolute, maxSteps: 1000)
        XCTAssertEqual(try XCTUnwrap(got), -3, accuracy: 0.5)
    }

    func testStepConvergesUp() async throws {
        let (bridge, s, d) = try await makeSliderBridge(min: 0, max: 480, start: 0, stepMode: true) {
            "\($0 / 10) %"                         // display = raw/10; step is ±10 raw → ±1 %
        }
        let got = try await bridge.convergeAdaptive(slider: s, display: d, target: 12,
                                                    tolerance: 0.5, actuation: .step, maxSteps: 1000)
        XCTAssertEqual(try XCTUnwrap(got), 12, accuracy: 0.5)
    }

    func testBinarySearchHandlesInverseDisplay() async throws {
        let (bridge, s, d) = try await makeSliderBridge(min: 0, max: 480, start: 0, stepMode: false) {
            "\((480 - $0) / 10) %"                 // display DECREASES as raw rises
        }
        let got = try await bridge.convergeAdaptive(slider: s, display: d, target: 12,
                                                    tolerance: 0.5, actuation: .absolute, maxSteps: 1000)
        XCTAssertEqual(try XCTUnwrap(got), 12, accuracy: 0.5)
    }

    func testUnreachableTargetReturnsNearestNotFabricated() async throws {
        let (bridge, s, d) = try await makeSliderBridge(min: 0, max: 480, start: 0, stepMode: false) {
            "\(($0 - 240) / 10) dB"                // reachable dB span is -24…+24
        }
        let got = try await bridge.convergeAdaptive(slider: s, display: d, target: 99,
                                                    tolerance: 0.5, actuation: .absolute, maxSteps: 1000)
        XCTAssertEqual(try XCTUnwrap(got), 24, accuracy: 0.5)   // clamps at the +24 dB rail, honestly
    }
}
