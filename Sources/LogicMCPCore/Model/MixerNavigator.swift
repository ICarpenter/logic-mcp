import Foundation

public actor MixerNavigator {
    private let session: MCUSession
    private let model: ProjectModel
    private(set) var bankOffset = 0
    private let settleWindow = Duration.milliseconds(150)

    public init(session: MCUSession, model: ProjectModel) {
        self.session = session
        self.model = model
    }

    private func lcdTop() async -> String {
        await session.surface.lcdTop
    }

    private func pressAndSettle(_ button: MCUButton) async -> Bool {
        let before = await lcdTop()
        await session.press(button)
        await session.settle(settleWindow)
        return await lcdTop() != before
    }

    private func bankFullyLeft() async {
        while await pressAndSettle(.bankLeft) {}
        bankOffset = 0
    }

    private func currentBankNames() async -> [String] {
        let surface = await session.surface
        return (0..<8).map { surface.lcdCell(line: 0, channel: $0) }
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    private func syncFadersFromSurface() async {
        let surface = await session.surface
        for ch in 0..<8 {
            let raw = surface.faderRaw[ch]
            guard raw >= 0 else { continue }
            let index = bankOffset + ch
            await model.updateTrack(index: index) {
                $0.volumeRaw = raw
                $0.volumeDB = FaderCurve.dB(fromRaw: raw)
                $0.volumeIsSilent = raw == 0
            }
        }
    }

    public func enumerateTracks() async throws -> [String] {
        await bankFullyLeft()
        var names = await currentBankNames().filter { !$0.isEmpty }
        guard !names.isEmpty else {
            throw ToolFailure(error: "mixer LCD is empty", layer: "mcu",
                              expected: "track names on the LCD",
                              observed: "blank display — is Logic running with the control surface installed?")
        }
        var banks = 1
        while banks < 32, await pressAndSettle(.bankRight) {
            bankOffset += 8
            banks += 1
            // Banks move in stride-8 windows; the last bank pads with blank cells,
            // so appending the non-blank cells of each new bank covers every track.
            names += await currentBankNames().filter { !$0.isEmpty }
        }
        await bankFullyLeft()
        await model.replaceTracks(names)
        await syncFadersFromSurface()
        return names
    }

    public func bank(toShow globalIndex: Int) async throws -> Int {
        while globalIndex >= bankOffset + 8 {
            guard await pressAndSettle(.bankRight) else {
                throw ToolFailure(error: "cannot bank to track \(globalIndex)", layer: "mcu",
                                  expected: "bank window containing index \(globalIndex)",
                                  observed: "mixer ends at offset \(bankOffset)")
            }
            bankOffset += 8
        }
        while globalIndex < bankOffset {
            guard await pressAndSettle(.bankLeft) else { break }
            bankOffset = max(0, bankOffset - 8)
        }
        await syncFadersFromSurface()
        return globalIndex - bankOffset
    }

    public func resolve(_ name: String) async throws -> TrackState {
        if await model.snapshot.staleAt != nil {
            _ = try await enumerateTracks()
        }
        return try await model.track(named: name)
    }
}
