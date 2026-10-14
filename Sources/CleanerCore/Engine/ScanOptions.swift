import Foundation

public struct ScanOptions: Codable, Equatable, Sendable {
    /// nil preserves the existing home-directory discovery; [] scans no projects.
    public var projectRoots: [String]?
    public var excludedPaths: [String]
    public var keptPaths: [String]
    public init(projectRoots: [String]? = nil, excludedPaths: [String] = [], keptPaths: [String] = []) {
        self.projectRoots = projectRoots
        self.excludedPaths = excludedPaths
        self.keptPaths = keptPaths
    }

    public func hasSameScope(as other: ScanOptions, home: String) -> Bool {
        func roots(_ paths: [String]) -> Set<String> {
            Set(paths.map { PathSafety.normalize($0, home: home) })
        }
        return roots(projectRoots ?? [home]) == roots(other.projectRoots ?? [home])
            && roots(excludedPaths) == roots(other.excludedPaths)
            && Set(keptPaths.map { PathSafety.normalize($0, home: home) }) == Set(other.keptPaths.map { PathSafety.normalize($0, home: home) })
    }
}

public struct ScanIssue: Codable, Equatable, Sendable, Identifiable {
    public var path: String
    public var message: String
    public var id: String { path + message }
    public init(path: String, message: String) { self.path = path; self.message = message }
}

public final class ScanDiagnostics {
    public init() {}
    public private(set) var issues: [ScanIssue] = []
    public func record(_ path: String, _ message: String) {
        let issue = ScanIssue(path: path, message: message)
        if !issues.contains(issue) { issues.append(issue) }
    }
}
