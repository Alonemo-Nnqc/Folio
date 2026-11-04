import Foundation

public enum LibraryError: Error, Equatable, LocalizedError {
    case emptyName
    case duplicateGroupName(String)
    case duplicateTagName(String)
    case groupDepthExceeded
    case notFound
    case invalidOperation(String)

    public var errorDescription: String? {
        switch self {
        case .emptyName: String(localized: "名称不能为空", bundle: .module)
        case .duplicateGroupName(let name): String(localized: "已存在名为「\(name)」的分组", bundle: .module)
        case .duplicateTagName(let name): String(localized: "已存在名为「\(name)」的标签", bundle: .module)
        case .groupDepthExceeded: String(localized: "分组最多支持两级", bundle: .module)
        case .notFound: String(localized: "找不到该项目", bundle: .module)
        case .invalidOperation(let reason): reason
        }
    }
}
