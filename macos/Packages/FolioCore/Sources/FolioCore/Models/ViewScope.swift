/// What the middle list shows.
public enum ViewScope: Hashable, Sendable {
    case all, unfiled, trash
    case group(String)
    case tag(String)
    /// 阅读: the papers being read, not read yet, or read.
    case status(ReadStatus)

    /// Stable key used for per-view ordering and sort persistence.
    public var key: String {
        switch self {
        case .all: "all"
        case .unfiled: "unfiled"
        case .trash: "trash"
        case .group(let id): "group:\(id)"
        case .tag(let id): "tag:\(id)"
        case .status(let status): "status:\(status.rawValue)"
        }
    }

    public var groupId: String? {
        if case .group(let id) = self { id } else { nil }
    }
}
