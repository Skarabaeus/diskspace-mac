import Darwin
import Foundation

/// Recursively computes folder sizes with allocation-aware byte counts, skipping cross-device
/// directories and not traversing directory symlinks.
enum FolderScanner {
    private static let progressEveryNItems = 64

    private struct FileID: Hashable {
        let dev: dev_t
        let ino: ino_t
    }

    /// - Parameters:
    ///   - root: Folder URL (must be security-scoped if sandboxed).
    ///   - progress: Called on arbitrary threads with `(path, itemsScanned)`.
    static func scan(
        root: URL,
        progress: @escaping @Sendable (String, Int64) -> Void
    ) async throws -> FolderNode {
        var rootStat = stat()
        guard stat(root.path, &rootStat) == 0 else {
            throw NSError(
                domain: NSCocoaErrorDomain,
                code: NSFileReadNoPermissionError,
                userInfo: [NSLocalizedDescriptionKey: "Cannot read \(root.path)"]
            )
        }
        let rootDevice = rootStat.st_dev
        var visited = Set<FileID>()
        var itemsScanned: Int64 = 0

        func bumpProgress(path: String) {
            itemsScanned += 1
            if itemsScanned % Int64(Self.progressEveryNItems) == 0 {
                progress(path, itemsScanned)
            }
        }

        func visit(_ url: URL, name: String) async throws -> FolderNode {
            try Task.checkCancellation()

            var st = stat()
            if lstat(url.path, &st) != 0 {
                let err = errno
                let msg = String(cString: strerror(err))
                return FolderNode(
                    name: name,
                    totalBytes: 0,
                    children: nil,
                    errorMessage: "lstat: \(msg)"
                )
            }

            let mode = st.st_mode & S_IFMT

            if mode == S_IFLNK {
                if Self.isDirectorySymlink(url) {
                    // Report only the symlink entry itself (a few bytes), not the target tree.
                    // Following directory symlinks would risk double-counting entire subtrees.
                    bumpProgress(path: url.path)
                    return FolderNode(
                        name: name,
                        totalBytes: Int64(st.st_size),
                        children: nil,
                        errorMessage: nil
                    )
                }
                // File symlinks: report the target's allocated size, not the symlink metadata size.
                let bytes = Self.allocatedBytes(
                    for: url.resolvingSymlinksInPath(),
                    fallbackLogicalSize: Int64(st.st_size)
                )
                bumpProgress(path: url.path)
                return FolderNode(name: name, totalBytes: bytes, children: nil, errorMessage: nil)
            }

            if mode == S_IFDIR {
                if st.st_dev != rootDevice {
                    bumpProgress(path: url.path)
                    return FolderNode(
                        name: name,
                        totalBytes: 0,
                        children: nil,
                        errorMessage: "Other volume (skipped)"
                    )
                }

                let fid = FileID(dev: st.st_dev, ino: st.st_ino)
                if visited.contains(fid) {
                    return FolderNode(
                        name: name,
                        totalBytes: 0,
                        children: nil,
                        errorMessage: "Already visited (cycle)"
                    )
                }

                let (childURLs, listError) = Self.directoryContents(url)
                if let listError {
                    bumpProgress(path: url.path)
                    return FolderNode(
                        name: name,
                        totalBytes: 0,
                        children: nil,
                        errorMessage: listError
                    )
                }

                visited.insert(fid)

                var children: [FolderNode] = []
                children.reserveCapacity(childURLs.count)
                var total: Int64 = 0

                for child in childURLs {
                    try Task.checkCancellation()
                    let childName = child.lastPathComponent
                    let node = try await visit(child, name: childName)
                    children.append(node)
                    total += node.totalBytes
                }

                bumpProgress(path: url.path)
                return FolderNode(name: name, totalBytes: total, children: children, errorMessage: nil)
            }

            if mode == S_IFREG {
                // Deduplicate hard links: only count an inode's bytes the first time we see it.
                if st.st_nlink > 1 {
                    let fid = FileID(dev: st.st_dev, ino: st.st_ino)
                    if visited.contains(fid) {
                        bumpProgress(path: url.path)
                        return FolderNode(name: name, totalBytes: 0, children: nil, errorMessage: "Hard link (already counted)")
                    }
                    visited.insert(fid)
                }
                let bytes = Self.allocatedBytes(for: url, fallbackLogicalSize: Int64(st.st_size))
                bumpProgress(path: url.path)
                return FolderNode(name: name, totalBytes: bytes, children: nil, errorMessage: nil)
            }

            bumpProgress(path: url.path)
            return FolderNode(name: name, totalBytes: Int64(st.st_size), children: nil, errorMessage: nil)
        }

        let rootName = root.lastPathComponent.isEmpty ? root.path : root.lastPathComponent
        var tree = try await visit(root, name: rootName)
        tree.sortChildrenBySizeDescending()
        progress(root.path, itemsScanned)
        return tree
    }

    /// Returns directory entries, or an empty list plus a message when listing fails (e.g. permission denied).
    private static func directoryContents(_ url: URL) -> ([URL], String?) {
        do {
            let urls = try FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: nil,
                options: []
            )
            return (urls, nil)
        } catch {
            return ([], error.localizedDescription)
        }
    }

    private static func isDirectorySymlink(_ url: URL) -> Bool {
        do {
            let dest = try FileManager.default.destinationOfSymbolicLink(atPath: url.path)
            let base = url.deletingLastPathComponent()
            let resolved = URL(fileURLWithPath: dest, relativeTo: base).standardizedFileURL
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDir) {
                return isDir.boolValue
            }
        } catch {
            return false
        }
        return false
    }

    /// Uses allocated size from resource values when readable; otherwise falls back to `lstat` logical size.
    private static func allocatedBytes(for url: URL, fallbackLogicalSize: Int64) -> Int64 {
        do {
            let values = try url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
            if let alloc = values.totalFileAllocatedSize {
                return Int64(alloc)
            }
            if let size = values.fileSize {
                return Int64(size)
            }
        } catch {
        }
        return fallbackLogicalSize
    }
}
