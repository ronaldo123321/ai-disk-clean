import Foundation
import Darwin

/// Walk each directory component without following links. macOS /var and /tmp are canonical aliases.
enum SafeDirectory {
    static func remove(_ path: String) throws {
        let parent = try parent(of: path)
        defer { close(parent.fd) }
        var info = stat()
        guard fstatat(parent.fd, parent.name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw FileOpError.posix(path: path, errno: errno, context: "读取删除对象")
        }
        try removeEntry(parentFD: parent.fd, name: parent.name, device: info.st_dev, path: path)
    }
    private static func removeEntry(parentFD: Int32, name: String, device: dev_t, path: String) throws {
        var info = stat()
        guard fstatat(parentFD, name, &info, AT_SYMLINK_NOFOLLOW) == 0, info.st_dev == device else {
            throw FileOpError.posix(path: path, errno: EXDEV, context: "删除边界变化")
        }
        if (info.st_mode & S_IFMT) != S_IFDIR {
            guard unlinkat(parentFD, name, 0) == 0 else { throw FileOpError.posix(path: path, errno: errno, context: "删除文件或链接") }
            return
        }
        let fd = openat(parentFD, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw FileOpError.refuseSymlink(path) }
        defer { close(fd) }
        var opened = stat()
        guard fstat(fd, &opened) == 0, opened.st_dev == info.st_dev, opened.st_ino == info.st_ino else {
            throw FileOpError.refuseSymlink(path)
        }
        let duplicate = dup(fd)
        guard duplicate >= 0 else { throw FileOpError.posix(path: path, errno: errno, context: "读取目录") }
        guard let stream = fdopendir(duplicate) else { close(duplicate); throw FileOpError.posix(path: path, errno: errno, context: "读取目录") }
        defer { closedir(stream) }
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                if errno != 0 { throw FileOpError.posix(path: path, errno: errno, context: "遍历目录") }
                break
            }
            let child = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: 1024) { String(cString: $0) }
            }
            if child == "." || child == ".." { continue }
            try removeEntry(parentFD: fd, name: child, device: device, path: path + "/" + child)
        }
        var current = stat()
        guard fstatat(parentFD, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
              current.st_dev == opened.st_dev, current.st_ino == opened.st_ino,
              unlinkat(parentFD, name, AT_REMOVEDIR) == 0 else { throw FileOpError.refuseSymlink(path) }
    }

    static func parent(of path: String) throws -> (fd: Int32, name: String) {
        var canonical = path
        for (alias, target) in [("/var", "/private/var"), ("/tmp", "/private/tmp")] {
            if path.hasPrefix(alias + "/"), RealFileOperations().realPath(ofPath: alias) == target {
                canonical = target + path.dropFirst(alias.count)
            }
        }
        guard canonical.hasPrefix("/"), !canonical.split(separator: "/").contains("..") else { throw FileOpError.refuseSymlink(path) }
        let parts = canonical.split(separator: "/").map(String.init)
        guard let name = parts.last else { throw FileOpError.refuseSymlink(path) }
        var fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw FileOpError.posix(path: path, errno: errno, context: "打开根目录") }
        for component in parts.dropLast() {
            let next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            close(fd)
            guard next >= 0 else {
                // 区分权限拦截（如 macOS 对 ~/.Trash 的隐私保护）与真实的链接拒绝
                if errno == EPERM || errno == EACCES {
                    throw FileOpError.posix(path: path, errno: errno,
                                            context: "无权访问（macOS 可能要求授权，请在弹窗中允许或授予完全磁盘访问权限）")
                }
                throw FileOpError.refuseSymlink(path)
            }
            fd = next
        }
        return (fd, name)
    }
}
