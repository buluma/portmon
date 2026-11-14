import Foundation
import Darwin

/// Runs a short-lived command with bounded time and output, draining both pipes.
public enum ProcessRunner {
    public struct Result: Sendable {
        public let output: Data
        public let status: Int32
    }

    public static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 10) -> Result? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        let deadline = DispatchTime.now() + timeout
        do { try process.run() } catch { return nil }
        let buffer = OutputBuffer()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            while true {
                let data = pipe.fileHandleForReading.availableData
                if data.isEmpty { break }
                if buffer.data.count < 8 * 1024 * 1024 {
                    buffer.data.append(data.prefix(8 * 1024 * 1024 - buffer.data.count))
                }
            }
            done.signal()
        }
        if done.wait(timeout: deadline) == .timedOut || exited.wait(timeout: deadline) == .timedOut {
            if process.isRunning { process.terminate() }
            if done.wait(timeout: .now() + 0.5) == .timedOut {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                // Descendants may still hold the pipe; do not wait indefinitely.
                return nil
            }
            process.waitUntilExit()
            return nil
        }
        return Result(output: buffer.data, status: process.terminationStatus)
    }

    private final class OutputBuffer: @unchecked Sendable {
        var data = Data()
    }
}
