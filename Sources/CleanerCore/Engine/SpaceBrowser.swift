import Foundation

public struct SpaceEntry: Identifiable, Equatable {
    public var id: String { path }
    public var path: String
    public var bytes: Int64?
    public var directory: Bool
    public var note: String?
}

public struct SpaceListing: Equatable {
    public var path: String
    public var entries: [SpaceEntry]
    public var incomplete: Bool
}

/// Read-only, bounded directory inventory. Never follows links or enters privacy/excluded roots.
public struct SpaceBrowser {
    public let files: FileOperations
    public init(files: FileOperations) { self.files = files }

    public func list(_ path: String, options: ScanOptions, cancellation: OperationCancellation,
                     limit: Int = 50_000) throws -> SpaceListing {
        let home = files.homeDirectory()
        let safety = PathSafety(home: home, files: files)
        let forbidden = RuleValidator.privacyRoots(home: home) + safety.treeForbiddenRoots
            + options.excludedPaths + [home + "/Downloads", home + "/Library/Containers", home + "/Library/Group Containers"]
        func blocked(_ p: String) -> Bool {
            forbidden.contains { PathSafety.isInside(p.lowercased(), root: safety.normalize($0).lowercased()) }
        }
        guard PathSafety.isInside(path, root: home), !blocked(path),
              EnginePathChecks.isCanonical(path, files: files),
              files.attributesIfExist(atPath: path)?.isDirectory == true else { throw FileOpError.refuseSymlink(path) }
        let device = files.attributesIfExist(atPath: home)?.device
        var visited = 0
        let deadline = Date().addingTimeInterval(10)
        var entries: [SpaceEntry] = []
        for child in try files.childrenOfDirectory(atPath: path) {
            var bytes: Int64 = 0
            var incomplete = false
            var stack = [child]
            var seen = Set<String>()
            while let current = stack.popLast() {
                if cancellation.isCancelled || visited >= limit || Date() >= deadline { incomplete = true; break }
                visited += 1
                guard !blocked(current), let attr = files.attributesIfExist(atPath: current),
                      !attr.isSymbolicLink, attr.device == device,
                      EnginePathChecks.isCanonical(current, files: files) else { incomplete = true; continue }
                if attr.isDirectory {
                    do { stack.append(contentsOf: try files.childrenOfDirectory(atPath: current)) }
                    catch { incomplete = true }
                } else {
                    if let inode = attr.inode, let device = attr.device,
                       !seen.insert("\(device):\(inode)").inserted { continue }
                    bytes += attr.allocatedSize
                }
            }
            let attr = files.attributesIfExist(atPath: child)
            entries.append(SpaceEntry(path: child, bytes: incomplete ? nil : bytes,
                directory: attr?.isDirectory == true && attr?.isSymbolicLink == false && !blocked(child) && attr?.device == device,
                note: incomplete ? "未完整统计（受保护、不可读或达到扫描上限）" : nil))
        }
        return SpaceListing(path: path, entries: entries.sorted {
            if $0.bytes != $1.bytes { return ($0.bytes ?? -1) > ($1.bytes ?? -1) }
            return $0.path < $1.path
        }, incomplete: entries.contains { $0.bytes == nil })
    }
}
