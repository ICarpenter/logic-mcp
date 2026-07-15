public final class Daemon: Sendable {
    public let session: MCUSession
    public let model: ProjectModel
    public let navigator: MixerNavigator
    public let ax: AXBridge
    public let axMixer: AXMixer
    public let menu: AXMenuDriver
    public let journal = UndoJournal()
    /// Stat'd HERE, at daemon startup — this is the moment the running code was loaded, so the
    /// mtime captured now belongs to the build we are actually executing. A later `swift build`
    /// writes a new file at the same path, and `ping` catches the divergence. Defaulted so the
    /// test suite (which spins up daemons constantly) needs no filesystem.
    public let buildStamp: BuildStamp

    public init(wire: MCUWire, axProvider: AXProvider, buildStamp: BuildStamp = .unknown) async {
        self.buildStamp = buildStamp
        session = MCUSession(wire: wire)
        model = ProjectModel()
        navigator = MixerNavigator(session: session, model: model)
        ax = AXBridge(provider: axProvider)
        axMixer = AXMixer(bridge: ax, model: model)
        menu = AXMenuDriver(provider: axProvider)
        await session.start()
    }

    // MARK: - The mixer entry point (BUG 2)
    //
    // Every AX mixer tool addresses strips through `mixerStrip(named:)` or `syncMixer()`, and both
    // go through `ensureMixerWindow()` first. `AXBridge.mixerArea()` is STRICT (it binds only a
    // mixer area inside a window titled "…Mixer…", else throws) because the arrange window's
    // Inspector holds a MINI-MIXER with the identical role+description: binding that returned 2
    // strips REPORTING SUCCESS and silently replaced the shadow model.
    //
    // The self-heal lives HERE, not in AXBridge: opening the Mixer is a MENU press, and AXBridge
    // has no menu driver (it is the read/write surface; `AXMenuDriver` is the actuator). The
    // Daemon is the one object that holds both, so it is the natural seam — AXBridge stays
    // bind-or-throw and testable without a menu bar, and the layering is unchanged.

    /// Make sure Logic's Mixer WINDOW is open, opening it if not. `Window ▸ Open Mixer` is a plain
    /// menu item (no ellipsis, no dialog) and `pressMenuPath` is background-safe — it does NOT
    /// steal focus, same primitive `create_track` uses. Settle-polls afterwards: Logic's AX tree
    /// updates ASYNCHRONOUSLY after a menu press (~700ms observed), so the window does NOT appear
    /// synchronously and a single re-read would wrongly conclude the press failed.
    public func ensureMixerWindow(timeout: Duration = .seconds(3)) async throws {
        if await ax.hasMixerWindow() { return }
        try await menu.pressMenuPath(["Window", "Open Mixer"])
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
            if await ax.hasMixerWindow() { return }
        }
        throw ToolFailure(
            error: "no mixer surface — could not open Logic's Mixer window", layer: "ax",
            expected: "a window titled \"…Mixer…\" after pressing Window ▸ Open Mixer",
            observed: "pressed Window ▸ Open Mixer but no Mixer window appeared within \(timeout). Open the Mixer in Logic (⌘2). Refusing to fall back to the arrange window's Inspector mini-mixer, which shows only the selected track and would corrupt the shadow model.")
    }

    /// Resolve a track name to its MIXER-WINDOW strip, self-healing the window first.
    public func mixerStrip(named name: String) async throws -> AXHandle {
        try await ensureMixerWindow()
        return try await ax.find(name)
    }

    /// Re-read the whole mixer into the shadow model, self-healing the window first. The ONLY
    /// path that may replace the model — a degraded read must never get this far.
    @discardableResult
    public func syncMixer() async throws -> [String] {
        try await ensureMixerWindow()
        return try await axMixer.syncTracks()
    }

    public func registerAllTools(in registry: ToolRegistry) async {
        await registry.register(PingTool(version: "0.1.0",
                                        runningBuildTime: buildStamp.runningBuildTime,
                                        diskBuildTime: buildStamp.diskBuildTime))
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
        await registry.register(CreateTrackTool(daemon: self))
        await registry.register(RenameTrackTool(daemon: self))
        await registry.register(SelectTrackTool(daemon: self))
        await registry.register(DeleteTrackTool(daemon: self))
        await registry.register(SetOutputTool(daemon: self))
        await registry.register(InsertPluginTool(daemon: self))
        await registry.register(UndoStructuralTool(daemon: self))
        await registry.register(UndoLastTool(daemon: self, registry: registry))
    }
}
