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
        case .emptyName: "名称不能为空"
        case .duplicateGroupName(let name): "已存在名为「\(name)」的分组"
        case .duplicateTagName(let name): "已存在名为「\(name)」的标签"
        case .groupDepthExceeded: "分组最多支持两级"
        case .notFound: "找不到该项目"
        case .invalidOperation(let reason): reason
        }
    }
}
