import Foundation

public struct DetectContext {
    public let files: FileOperations
    public let safety: PathSafety
    public let runner: ProcessRunner
    public let now: Date
    public let cancellation: OperationCancellation?

    public init(files: FileOperations, safety: PathSafety, runner: ProcessRunner, now: Date,
                cancellation: OperationCancellation? = nil) {
        self.files = files
        self.safety = safety
        self.runner = runner
        self.now = now
        self.cancellation = cancellation
    }

    public var home: String { files.homeDirectory() }
    public var isCancelled: Bool { cancellation?.isCancelled == true }
}

/// 识别器只读：只能查看文件与运行只读命令，产出清理项，不做任何修改。
public protocol Detector {
    /// 扫描进度里显示的名称
    var name: String { get }
    func detect(_ context: DetectContext) -> [CleanItem]
}

public enum ScanStep: Equatable, Sendable {
    case detecting(String)
    case sizing(done: Int, total: Int)
    case spaceMap
    case checkingBlockers

    public var title: String {
        switch self {
        case .detecting(let name): return "正在识别\(name)"
        case .sizing(let done, let total): return "正在计算大小（\(done)/\(total)）"
        case .spaceMap: return "正在查看其他大目录"
        case .checkingBlockers: return "正在检查占用"
        }
    }
}
