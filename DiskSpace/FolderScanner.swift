import Darwin
import Foundation

/// Recursively computes folder sizes with allocation-aware byte counts, skipping cross-device
/// directories and not traversing directory symlinks.
enum FolderScanner {
    private static let progressEveryNItems = 64

    /// App library bundles: recursing touches many DB files and triggers repeated TCC prompts.
    private static let opaqueLibraryExtensions: Set<String> = [
        "photoslibrary", "photolibrary", "musiclibrary", "tvlibrary",
    ]

    private struct FileID: Hashable {
        let dev: dev_t
        let ino: ino_t
    }

    /// - Parameters:
    ///   - root: Folder URL (must be security-scoped if sandboxed).
    ///   - progress: Called on the caller's thread with `(path, itemsScanned)`.
    static func scan(
        root: URL,
        progress: @escaping @Sendable (String, Int64) -> Void
    ) throws -> FolderNode {
        let rootPath = (root.standardizedFileURL.path as NSString).standardizingPath

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

        func visit(_ url: URL, name: String) throws -> FolderNode {
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
                if Self.isDirectorySymlink(url, rootStandardPath: rootPath) {
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
                // File symlinks: size the target only when it stays under the user-selected root.
                // Do not call resolvingSymlinksInPath() first — it can probe unsandboxed paths and
                // trigger repeated privacy prompts.
                let bytes: Int64
                if let dest = try? FileManager.default.destinationOfSymbolicLink(atPath: url.path) {
                    let base = url.deletingLastPathComponent()
                    let resolved = URL(fileURLWithPath: dest, relativeTo: base).standardizedFileURL
                    if Self.isDescendantPath(resolved.path, ofRoot: rootPath) {
                        bytes = Self.allocatedBytes(
                            for: resolved,
                            fallbackLogicalSize: Int64(st.st_size)
                        )
                    } else {
                        bytes = Int64(st.st_size)
                    }
                } else {
                    bytes = Int64(st.st_size)
                }
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

                if Self.isOpaqueSystemLibrary(url) {
                    visited.insert(fid)
                    try Task.checkCancellation()
                    let (bytes, opaqueErr) = Self.opaqueLibraryDiskUsageBytes(at: url.path)
                    bumpProgress(path: url.path)
                    return FolderNode(
                        name: name,
                        totalBytes: bytes,
                        children: nil,
                        errorMessage: opaqueErr
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
                    let node = try visit(child, name: childName)
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
        var tree = try visit(root, name: rootName)
        tree.sortChildrenBySizeDescending()
        progress(root.path, itemsScanned)
        return tree
    }

    private static func isOpaqueSystemLibrary(_ url: URL) -> Bool {
        opaqueLibraryExtensions.contains(url.pathExtension.lowercased())
    }

    /// One `du` pass instead of opening every file inside Photos/Music/TV library packages.
    private static func opaqueLibraryDiskUsageBytes(at path: String) -> (Int64, String?) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/du")
        p.arguments = ["-sk", path]

        let outPipe = Pipe()
        let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe

        do {
            try p.run()
        } catch {
            return (0, "Could not measure library size")
        }

        p.waitUntilExit()

        if p.terminationStatus != 0 {
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let errText = String(data: errData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let suffix = errText.isEmpty ? "" : ": \(errText)"
            return (0, "Could not measure library size\(suffix)")
        }

        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        guard
            let line = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .split(whereSeparator: \.isWhitespace).first,
            let kb = Int64(line)
        else {
            return (0, "Could not parse library size")
        }
        return (kb * 1024, nil)
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

    private static func isDescendantPath(_ path: String, ofRoot rootPath: String) -> Bool {
        let p = (path as NSString).standardizingPath
        let r = (rootPath as NSString).standardizingPath
        if p == r { return true }
        let prefix = r.hasSuffix("/") ? r : r + "/"
        return p.hasPrefix(prefix)
    }

    private static func isDirectorySymlink(_ url: URL, rootStandardPath: String) -> Bool {
        do {
            let dest = try FileManager.default.destinationOfSymbolicLink(atPath: url.path)
            let base = url.deletingLastPathComponent()
            let resolved = URL(fileURLWithPath: dest, relativeTo: base).standardizedFileURL
            guard isDescendantPath(resolved.path, ofRoot: rootStandardPath) else {
                return false
            }
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
