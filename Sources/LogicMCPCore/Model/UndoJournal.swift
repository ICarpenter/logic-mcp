public struct MixMutation: Sendable, Codable {
    public var tool: String
    public var track: String
    public var undoArguments: [String: String]?
    public var descriptionText: String
    public init(tool: String, track: String, undoArguments: [String: String]?, descriptionText: String) {
        self.tool = tool
        self.track = track
        self.undoArguments = undoArguments
        self.descriptionText = descriptionText
    }
}

public actor UndoJournal {
    public private(set) var entries: [MixMutation] = []
    public init() {}
    public func record(_ mutation: MixMutation) { entries.append(mutation) }
    public func popLast(_ n: Int) -> [MixMutation] {
        let count = max(0, min(n, entries.count))
        let popped = Array(entries.suffix(count).reversed())
        entries.removeLast(count)
        return popped
    }
}
