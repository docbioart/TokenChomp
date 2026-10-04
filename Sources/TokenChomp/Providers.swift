import Foundation
import Darwin
import ChompCore

struct ProviderFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum CodexProvider {
    static func collect(executable: String) throws -> [Quota] {
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["app-server"]
        process.standardInput = input; process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
        process.environment = env
        do { try process.run() } catch {
            throw ProviderFailure(message: "Choose your Codex executable below, then refresh. Run codex login in Terminal first.")
        }
        defer {
            try? input.fileHandleForWriting.close()
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            try? output.fileHandleForReading.close()
        }
        let deadline = Date().addingTimeInterval(15)
        var pending = Data()
        func send(_ object: [String: Any]) throws {
            var data = try JSONSerialization.data(withJSONObject: object)
            data.append(10)
            try input.fileHandleForWriting.write(contentsOf: data)
        }
        func response(id: Int) throws -> Data {
            while Date() < deadline {
                if let newline = pending.firstIndex(of: 10) {
                    let line = Data(pending[..<newline])
                    pending.removeSubrange(...newline)
                    guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
                    let matches = (object["id"] as? Int) == id || (object["id"] as? String) == String(id)
                    if matches {
                        if object["error"] != nil { throw ProviderFailure(message: "Codex could not report quota. Check CLI sign-in and version.") }
                        return line
                    }
                    continue
                }
                var descriptor = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
                let milliseconds = Int32(max(1, deadline.timeIntervalSinceNow * 1000))
                let ready = poll(&descriptor, 1, milliseconds)
                if ready == 0 { break }
                if ready < 0 {
                    if errno == EINTR { continue }
                    throw ProviderFailure(message: "Codex connection interrupted. Refresh to reconnect.")
                }
                var bytes = [UInt8](repeating: 0, count: 4096)
                let count = bytes.withUnsafeMutableBytes { Darwin.read(descriptor.fd, $0.baseAddress, $0.count) }
                guard count > 0 else { throw ProviderFailure(message: "Codex stopped before reporting quota. Check CLI sign-in and version.") }
                pending.append(contentsOf: bytes.prefix(count))
                guard pending.count <= 1_048_576 else { throw ProviderFailure(message: "Codex response was too large.") }
            }
            throw ProviderFailure(message: "Codex timed out. Refresh to reconnect.")
        }
        try send(["id": 1, "method": "initialize", "params": ["clientInfo": ["name": "tokenchomp", "version": "0.1.0"]]])
        _ = try response(id: 1)
        try send(["method": "initialized"])
        try send(["id": 2, "method": "account/rateLimits/read"])
        let quotas = try QuotaParser.codex(response(id: 2))
        guard !quotas.isEmpty else { throw ProviderFailure(message: "This Codex account did not report subscription quota.") }
        return quotas
    }
    static var defaultExecutable: String {
        ["/opt/homebrew/bin/codex", "/usr/local/bin/codex"].first {
            FileManager.default.isExecutableFile(atPath: $0)
        } ?? "/opt/homebrew/bin/codex"
    }
}

func runClaudeBridge() throws {
    let data = FileHandle.standardInput.readData(ofLength: 1_048_577)
    guard data.count <= 1_048_576 else { throw ProviderFailure(message: "Input too large") }
    let incoming = try QuotaParser.claude(data)
    guard !incoming.isEmpty else { return }
    try FileManager.default.createDirectory(at: LocalState.directory, withIntermediateDirectories: true,
                                           attributes: [.posixPermissions: 0o700])
    let lock = open(LocalState.directory.appendingPathComponent("claude.lock").path, O_CREAT | O_RDWR, 0o600)
    guard lock >= 0 else { throw ProviderFailure(message: "Cannot open bridge lock") }
    defer { close(lock) }
    // Bounded acquisition: an overlapping update may be dropped; no CLI session hangs.
    guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { return }
    defer { flock(lock, LOCK_UN) }
    try LocalState.saveClaude(incoming)
    print("TokenChomp · " + incoming.map { "\($0.title) \(Int($0.remaining))% left" }.joined(separator: " · "))
}
