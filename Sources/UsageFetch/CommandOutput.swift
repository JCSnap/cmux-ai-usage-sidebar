import Foundation

/// Runs a command and returns its standard output.
public enum CommandOutput {
    /// The output of `argv`, or nil when it cannot start, exits non-zero, or
    /// runs past `timeout`. Standard input and standard error are discarded.
    public static func run(_ argv: [String], timeout: TimeInterval = 30) async -> String? {
        guard let executable = argv.first else { return nil }
        return await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = Array(argv.dropFirst())
                let output = Pipe()
                process.standardOutput = output
                process.standardError = FileHandle.nullDevice
                process.standardInput = FileHandle.nullDevice
                do { try process.run() } catch {
                    continuation.resume(returning: nil)
                    return
                }
                let stop = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: stop)
                // Read to the end before waiting, so a large output cannot fill the pipe and stall.
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                stop.cancel()
                let ok = process.terminationStatus == 0 && process.terminationReason == .exit
                continuation.resume(returning: ok ? String(decoding: data, as: UTF8.self) : nil)
            }
        }
    }
}
