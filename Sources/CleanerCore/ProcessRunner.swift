import Foundation
import Darwin

// MARK: - 进程执行抽象（guard 与 command 策略的单测注入点）

public struct ProcessResult: Equatable, Sendable {
    public var exitStatus: Int32
    public var stdout: String
    public var stderr: String

    public init(exitStatus: Int32, stdout: String, stderr: String) {
        self.exitStatus = exitStatus
        self.stdout = stdout
        self.stderr = stderr
    }
}

public protocol ProcessRunner: AnyObject {
    /// launchPath 必须是完整路径；返回进程结果，启动失败（可执行文件不存在等）返回 nil。
    func run(launchPath: String, arguments: [String]) -> ProcessResult?
}

public final class RealProcessRunner: ProcessRunner {
    private let timeout: TimeInterval
    private let outputLimit: Int
    public init(timeout: TimeInterval = 10, outputLimit: Int = 1_048_576) {
        self.timeout = timeout
        self.outputLimit = outputLimit
    }
    public func run(launchPath: String, arguments: [String]) -> ProcessResult? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        do { try process.run() } catch { return nil }
        stdout.fileHandleForWriting.closeFile()
        stderr.fileHandleForWriting.closeFile()
        let outFD = stdout.fileHandleForReading.fileDescriptor
        let errFD = stderr.fileHandleForReading.fileDescriptor
        defer { stdout.fileHandleForReading.closeFile(); stderr.fileHandleForReading.closeFile() }
        guard fcntl(outFD, F_SETFL, O_NONBLOCK) == 0, fcntl(errFD, F_SETFL, O_NONBLOCK) == 0 else {
            kill(process.processIdentifier, SIGKILL); process.waitUntilExit(); return nil
        }
        var out = Data(), err = Data()
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        func drain(_ fd: Int32, into data: inout Data) -> Bool {
            var buffer = [UInt8](repeating: 0, count: 8192)
            while true {
                let count = Darwin.read(fd, &buffer, buffer.count)
                if count > 0 {
                    guard data.count + count <= outputLimit else { return false }
                    data.append(contentsOf: buffer.prefix(count))
                } else if count == 0 || errno == EAGAIN { return true }
                else if errno != EINTR { return false }
            }
        }
        while true {
            guard drain(outFD, into: &out), drain(errFD, into: &err),
                  ProcessInfo.processInfo.systemUptime < deadline else {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                process.waitUntilExit()
                return nil // Unknown, never interpreted as an idle guard.
            }
            if !process.isRunning {
                guard drain(outFD, into: &out), drain(errFD, into: &err) else { return nil }
                return ProcessResult(exitStatus: process.terminationStatus,
                    stdout: String(decoding: out, as: UTF8.self), stderr: String(decoding: err, as: UTF8.self))
            }
            usleep(10_000)
        }
    }
}
