import Foundation
import Darwin

/// Runs a short-lived command with bounded time and output, draining both pipes.
public enum ProcessRunner {
    public struct Result: Sendable {
        public let output: Data
        public let status: Int32
        public let stderr: Data
    }

    public static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 10) -> Result? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        let errors = Pipe()
        process.standardOutput = pipe
        process.standardError = errors
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        let deadline = DispatchTime.now() + timeout
        do { try process.run() } catch { return nil }
        let buffer = OutputBuffer()
        let errorBuffer = OutputBuffer()
        let readers = DispatchGroup()
        for (handle, destination) in [(pipe.fileHandleForReading, buffer), (errors.fileHandleForReading, errorBuffer)] {
            readers.enter()
            DispatchQueue.global(qos: .utility).async {
                while true {
                    let data = handle.availableData
                    if data.isEmpty { break }
                    if destination.data.count < 8 * 1024 * 1024 {
                        destination.data.append(data.prefix(8 * 1024 * 1024 - destination.data.count))
                    }
                }
                readers.leave()
            }
        }
        if exited.wait(timeout: deadline) == .timedOut {
            if process.isRunning { process.terminate() }
            if exited.wait(timeout: .now() + 0.5) == .timedOut, process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
            return nil
        }
        guard readers.wait(timeout: deadline) == .success else { return nil }
        return Result(output: buffer.data, status: process.terminationStatus, stderr: errorBuffer.data)
    }

    private final class OutputBuffer: @unchecked Sendable {
        var data = Data()
    }
}
