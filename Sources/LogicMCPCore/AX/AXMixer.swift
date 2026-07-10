import Foundation

/// Reads the whole mixer into the shadow `ProjectModel` in one pass. No banking, no
/// truncation, no overlap geometry — AX addresses every strip regardless of visible bank.
public actor AXMixer {
    private let bridge: AXBridge
    private let model: ProjectModel
    public init(bridge: AXBridge, model: ProjectModel) {
        self.bridge = bridge; self.model = model
    }

    @discardableResult
    public func syncTracks() async throws -> [String] {
        let handles = try await bridge.stripHandles()
        var controls: [AXStripControls] = []
        for h in handles { controls.append(await bridge.read(h.handle)) }
        await model.replaceTracks(controls)
        return controls.map(\.name)
    }
}
