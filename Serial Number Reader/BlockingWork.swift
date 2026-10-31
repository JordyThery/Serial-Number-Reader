import Foundation

/// Runs blocking work (socket reads with timeouts, USB requests, child
/// processes, the administrator prompt) on its own threads, so it never ties
/// up the threads Swift concurrency shares with the rest of the app.
nonisolated enum BlockingWork {

    private static let queue = DispatchQueue(label: "be.jordythery.SerialNumberReader.blocking",
                                             qos: .userInitiated, attributes: .concurrent)

    /// Runs `work` on the blocking-work queue and returns its result.
    static func run<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try work() }) }
        }
    }

    /// Runs `work` on the blocking-work queue and returns its result.
    static func run<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: work()) }
        }
    }
}

/// A finished child process: its exit status and everything it wrote.
nonisolated struct ProcessOutput: Sendable {
    let status: Int32
    let output: Data
    let errors: Data

    var errorText: String {
        String(decoding: errors, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Runs a program to its end. Both pipes are read while it runs, so a
    /// program that writes a lot can never block on a full pipe. Blocking.
    static func run(_ executable: URL, _ arguments: [String]) throws -> ProcessOutput {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        let errorData = drainInBackground(errors)
        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return ProcessOutput(status: process.terminationStatus, output: outputData, errors: errorData())
    }

    /// Reads a pipe to its end on another thread; the returned closure waits
    /// for and returns everything read.
    static func drainInBackground(_ pipe: Pipe) -> @Sendable () -> Data {
        final class Box: @unchecked Sendable { var data = Data() }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        let handle = pipe.fileHandleForReading
        Thread.detachNewThread {
            box.data = handle.readDataToEndOfFile()
            done.signal()
        }
        return {
            done.wait()
            return box.data
        }
    }
}
