public final class Daemon: Sendable {
    public let session: MCUSession
    public let model: ProjectModel
    public let navigator: MixerNavigator
    public let ax: AXBridge
    public let axMixer: AXMixer
    public let menu: AXMenuDriver
    public let journal = UndoJournal()

    public init(wire: MCUWire, axProvider: AXProvider) async {
        session = MCUSession(wire: wire)
        model = ProjectModel()
        navigator = MixerNavigator(session: session, model: model)
        ax = AXBridge(provider: axProvider)
        axMixer = AXMixer(bridge: ax, model: model)
        menu = AXMenuDriver(provider: axProvider)
        await session.start()
    }

    public func registerAllTools(in registry: ToolRegistry) async {
        await registry.register(PingTool(version: "0.1.0"))
        await registry.register(GetProjectOverviewTool(daemon: self))
        await registry.register(GetTrackTool(daemon: self))
        await registry.register(RefreshStateTool(daemon: self))
        await registry.register(PlayTool(daemon: self))
        await registry.register(StopTool(daemon: self))
        await registry.register(ToggleCycleTool(daemon: self))
        await registry.register(RecordTool(daemon: self))
        await registry.register(SetVolumeTool(daemon: self))
        await registry.register(SetMuteTool(daemon: self))
        await registry.register(SetSoloTool(daemon: self))
        await registry.register(SetPanTool(daemon: self))
        await registry.register(SetAutomationModeTool(daemon: self))
        await registry.register(SetSendTool(daemon: self))
        await registry.register(GetPluginParamsTool(daemon: self))
        await registry.register(SetPluginParamTool(daemon: self))
        await registry.register(UndoLastTool(daemon: self, registry: registry))
    }
}
