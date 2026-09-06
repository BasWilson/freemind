import Foundation

public struct PaneGrid: Equatable, Sendable {
    public let columns: Int
    public let rows: Int
    public init(count: Int, width: Double, minimumPaneWidth: Double = 360) {
        guard count > 0 else { columns = 1; rows = 0; return }
        let fitting = max(1, Int((max(0, width) - 12) / (minimumPaneWidth + 8)))
        let balanced = max(1, Int(ceil(sqrt(Double(count)))))
        columns = min(count, fitting, balanced)
        rows = (count + columns - 1) / columns
    }
}
