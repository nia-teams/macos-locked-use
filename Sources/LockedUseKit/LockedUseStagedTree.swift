import Darwin
import Foundation
import LockedUseNative

/// Validates administrator-owned staging without changing signed bundle contents.
public enum LockedUseStagedTree {
    public enum Failure: Error, Equatable { case untrusted }

    public static func validate(_ root: URL, allowContainedSymlinksUnder allowedSymlinkRoot: URL? = nil) throws {
        try validate(root, allowContainedSymlinksUnder: allowedSymlinkRoot, owner: 0)
    }

    // Tests supply an owned stop ancestor (excluded); production checks through /.
    static func validate(_ root: URL, allowContainedSymlinksUnder allowedSymlinkRoot: URL? = nil,
                         owner: UInt32, trustedStopAncestor: URL? = nil) throws {
        let rootPath = try cleanPath(root)
        let stop = try trustedStopAncestor.map { try cleanPath($0) }
        if let stop { guard isInside(rootPath, stop) else { throw Failure.untrusted } }
        var ancestors = [String]()
        var cursor = rootPath
        while cursor != stop {
            ancestors.append(cursor)
            if cursor == "/" { break }
            cursor = (cursor as NSString).deletingLastPathComponent
        }
        // Check parents first: O_NOFOLLOW alone only protects the last component.
        for path in ancestors.reversed() {
            let info = try inspect(path, owner: owner)
            if path != rootPath {
                guard info.st_mode & S_IFMT == S_IFDIR else { throw Failure.untrusted }
            }
        }
        let rootInfo = try inspect(rootPath, owner: owner)
        guard rootInfo.st_mode & S_IFMT == S_IFDIR else {
            guard allowedSymlinkRoot == nil else { throw Failure.untrusted }
            return // A regular-file root is used for the installed daemon plist.
        }
        let allowed = try allowedSymlinkRoot.map { try cleanPath($0) }
        if let allowed {
            guard isInside(allowed, rootPath),
                  try inspect(allowed, owner: owner).st_mode & S_IFMT == S_IFDIR else { throw Failure.untrusted }
        }
        var directories = [rootPath]
        while let directory = directories.popLast() {
            guard try inspect(directory, owner: owner).st_mode & S_IFMT == S_IFDIR else { throw Failure.untrusted }
            let names: [String]
            do { names = try FileManager.default.contentsOfDirectory(atPath: directory) }
            catch { throw Failure.untrusted }
            for name in names {
                guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.utf8.contains(0) else {
                    throw Failure.untrusted
                }
                let path = (directory == "/" ? "" : directory) + "/" + name
                let info = try metadata(path, owner: owner)
                switch info.st_mode & S_IFMT {
                case S_IFDIR:
                    _ = try inspect(path, owner: owner)
                    directories.append(path)
                case S_IFREG:
                    _ = try inspect(path, owner: owner)
                case S_IFLNK:
                    guard let allowed, isInside(path, allowed) else { throw Failure.untrusted }
                    _ = try inspect(path, owner: owner, allowLink: true)
                    try resolve(path, within: allowed, owner: owner)
                default: throw Failure.untrusted
                }
            }
        }
    }

    private static func cleanPath(_ url: URL) throws -> String {
        let path = url.path
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard url.isFileURL, path.hasPrefix("/"), !path.utf8.contains(0),
              !parts.contains("."), !parts.contains("..") else { throw Failure.untrusted }
        return path == "/" ? path : "/" + path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private static func isInside(_ path: String, _ base: String) -> Bool {
        path != base && path.hasPrefix(base == "/" ? "/" : base + "/")
    }

    private static func metadata(_ path: String, owner: UInt32) throws -> stat {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_uid == owner else { throw Failure.untrusted }
        return info
    }

    @discardableResult
    private static func inspect(_ path: String, owner: UInt32, allowLink: Bool = false) throws -> stat {
        let info = try metadata(path, owner: owner)
        let kind = info.st_mode & S_IFMT
        let link = kind == S_IFLNK
        guard (link && allowLink) || [S_IFREG, S_IFDIR].contains(kind),
              link || info.st_mode & 0o6022 == 0 else { throw Failure.untrusted }
        // Symlink permission bits are not access controls (0777 is normal).
        let flags = O_RDONLY | O_CLOEXEC | (link ? O_SYMLINK : O_NOFOLLOW) | (kind == S_IFDIR ? O_DIRECTORY : 0)
        let fd = open(path, flags)
        guard fd >= 0 else { throw Failure.untrusted }
        defer { Darwin.close(fd) }
        var opened = stat()
        guard fstat(fd, &opened) == 0, opened.st_dev == info.st_dev, opened.st_ino == info.st_ino,
              opened.st_uid == owner, opened.st_mode & S_IFMT == kind,
              link || opened.st_mode & 0o6022 == 0, ocu_has_mutating_acl(fd) == 0 else { throw Failure.untrusted }
        return opened
    }

    private static func target(_ path: String) throws -> [String] {
        var bytes = [CChar](repeating: 0, count: Int(PATH_MAX))
        let count = Darwin.readlink(path, &bytes, bytes.count)
        guard count > 0, count < bytes.count,
              let text = String(bytes: bytes.prefix(count).map { UInt8(bitPattern: $0) }, encoding: .utf8), !text.hasPrefix("/") else { throw Failure.untrusted }
        var parts = text.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.dropLast().allSatisfy({ !$0.isEmpty }) else { throw Failure.untrusted }
        // foo/ means foo/.: the pending dot also forces chained targets to be directories.
        if parts.last == "" { parts[parts.count - 1] = "." }
        return parts
    }

    private static func resolve(_ path: String, within base: String, owner: UInt32) throws {
        // Walk from the containment root, including the original link's parents.
        var pending = String(path.dropFirst(base.count + 1)).split(separator: "/").map(String.init)
        var stack = [String]()
        var hops = 0
        while !pending.isEmpty {
            let component = pending.removeFirst()
            if component == "." { continue }
            if component == ".." {
                guard !stack.isEmpty else { throw Failure.untrusted }
                stack.removeLast()
                continue
            }
            let node = base + "/" + (stack + [component]).joined(separator: "/")
            let info = try inspect(node, owner: owner, allowLink: true)
            switch info.st_mode & S_IFMT {
            case S_IFLNK:
                hops += 1
                guard hops <= 16 else { throw Failure.untrusted }
                pending.insert(contentsOf: try target(node), at: 0)
            case S_IFDIR:
                stack.append(component)
            case S_IFREG:
                guard pending.isEmpty else { throw Failure.untrusted }
                stack.append(component)
            default: throw Failure.untrusted
            }
        }
        guard !stack.isEmpty else { throw Failure.untrusted }
        _ = try inspect(base + "/" + stack.joined(separator: "/"), owner: owner)
    }
}
