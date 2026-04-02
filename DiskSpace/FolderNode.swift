import Foundation

struct FolderNode: Identifiable, Sendable {
    let id: UUID
    var name: String
    /// Total bytes (recursive for folders; allocated size for files).
    var totalBytes: Int64
    var children: [FolderNode]?
    var errorMessage: String?

    init(
        id: UUID = UUID(),
        name: String,
        totalBytes: Int64,
        children: [FolderNode]? = nil,
        errorMessage: String? = nil
    ) {
        self.id = id
        self.name = name
        self.totalBytes = totalBytes
        self.children = children
        self.errorMessage = errorMessage
    }

    mutating func sortChildrenBySizeDescending() {
        guard var kids = children else { return }
        kids.sort { $0.totalBytes > $1.totalBytes }
        for i in kids.indices {
            kids[i].sortChildrenBySizeDescending()
        }
        children = kids
    }
}
