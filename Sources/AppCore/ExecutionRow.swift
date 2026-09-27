import Foundation
import CleanerCore

/// 执行页的一行（spec §3.4）：本次运行的每一项都列出，带当前状态。
public struct ExecutionRow: Equatable {
    public enum Status: Equatable {
        case waiting
        case running(step: String?)
        case done
        case skipped(String)
        case failed(String)

        public var title: String {
            switch self {
            case .waiting: return "等待"
            case .running: return "进行中"
            case .done: return "完成"
            case .skipped: return "跳过"
            case .failed: return "失败"
            }
        }
    }

    public var id: String
    public var title: String
    public var status: Status

    /// 已有结果的按结果；正在处理的那一项为进行中（带子步骤）；其余等待。
    public static func make(items: [CleanItem], progress: AppModel.ExecutionProgress) -> [ExecutionRow] {
        let results = Dictionary(progress.finished.map { ($0.itemID, $0) }, uniquingKeysWith: { first, _ in first })
        return items.enumerated().map { index, item in
            let status: Status
            if let result = results[item.id] {
                switch result.outcome {
                case .done: status = .done
                case .skipped(let why): status = .skipped(why)
                case .failed(let why): status = .failed(why)
                }
            } else if index == progress.currentIndex {
                status = .running(step: progress.currentStep)
            } else {
                status = .waiting
            }
            return ExecutionRow(id: item.id, title: item.title, status: status)
        }
    }
}
