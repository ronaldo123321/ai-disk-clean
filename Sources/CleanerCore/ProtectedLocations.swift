import Foundation

/// Shared by GUI and CLI; malformed settings fail closed at execution.
public final class ProtectedLocations {
    private let files: FileOperations
    private var path: String { V2Paths.dataDirectory(home: files.homeDirectory()) + "/protected.json" }
    public init(files: FileOperations) { self.files = files }
    public func read() throws -> [String] {
        guard files.fileExists(path) else { return [] }
        guard files.attributesIfExist(atPath: path)?.isSymbolicLink == false,
              let data = files.readFile(atPath: path) else { throw FileOpError.refuseSymlink(path) }
        let roots = try JSONDecoder().decode([String].self, from: data)
        guard roots.allSatisfy({ $0.hasPrefix("/") && $0 == PathSafety.normalize($0, home: files.homeDirectory()) }) else {
            throw FileOpError.refuseSymlink(path)
        }
        return roots
    }
    public func add(_ raw: String) throws {
        let lease = try OperationLease.acquire(files: files)
        defer { withExtendedLifetime(lease) {} }
        let normalized = PathSafety.normalize(raw, home: files.homeDirectory())
        guard normalized.hasPrefix("/"), files.fileExists(normalized) else { throw FileOpError.notFound(normalized) }
        let canonical = files.realPath(ofPath: normalized) ?? normalized
        try files.writeFile(try JSONEncoder().encode(Array(Set(try read() + [normalized, canonical])).sorted()), toPath: path)
    }
    public func remove(_ root: String) throws {
        let lease = try OperationLease.acquire(files: files)
        defer { withExtendedLifetime(lease) {} }
        try files.writeFile(try JSONEncoder().encode(read().filter { $0 != root }), toPath: path)
    }
}
