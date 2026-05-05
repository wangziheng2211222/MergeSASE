import Foundation

struct CommandResult {
    let exitCode: Int32
    let stdout: String
    let stderr: String
    var succeeded: Bool { exitCode == 0 }
}

struct CommandRunner {
    static func run(_ exec: String, _ args: [String]) async -> CommandResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: exec)
                process.arguments = args
                process.qualityOfService = .userInitiated

                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: CommandResult(exitCode: -1, stdout: "", stderr: error.localizedDescription))
                    return
                }
                process.waitUntilExit()

                let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

                continuation.resume(returning: CommandResult(
                    exitCode: process.terminationStatus,
                    stdout: stdout.trimmingCharacters(in: .whitespacesAndNewlines),
                    stderr: stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                ))
            }
        }
    }

    static func runShell(_ command: String) async -> CommandResult {
        await run("/bin/bash", ["-c", command])
    }
}
