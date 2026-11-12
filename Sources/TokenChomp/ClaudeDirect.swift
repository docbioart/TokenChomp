import Foundation
import IOKit.ps
import ChompCore

/// Polls the usage endpoint Claude Code itself uses, signed with Claude Code's own OAuth session.
/// The access token is read from the Keychain on every poll and never written anywhere. Claude Code
/// refreshes the token during its own sessions; this app never refreshes or rotates it.
///
/// The read goes through /usr/bin/security, exactly as Claude Code reads and writes the item. Claude Code
/// rewrites the item with `security add-generic-password -U` at every token refresh (about every 8 hours),
/// and that rewrite drops any per-app "Always Allow" grant, so a Security.framework read prompted again
/// after each refresh and after each rebuild of this ad-hoc-signed app. The security tool itself stays
/// authorized on the item, so this path does not prompt. The user opted in via the direct-poll toggle.
enum ClaudeUsageProvider {
    static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static func collect(maxAge: TimeInterval) async throws -> [Quota] {
        let token = try accessToken()
        var request = URLRequest(url: endpoint, timeoutInterval: 15)
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response): (Data, URLResponse)
        do { (data, response) = try await URLSession.shared.data(for: request) }
        catch { throw ProviderFailure(message: "Claude usage unreachable. Check your connection.") }
        switch (response as? HTTPURLResponse)?.statusCode ?? 0 {
        case 200: break
        case 401, 403: throw ProviderFailure(message: "Claude Code sign-in expired. Open Claude Code to refresh it.")
        case 429: throw ProviderFailure(message: "Claude usage endpoint is rate limited. Will retry.")
        case let code: throw ProviderFailure(message: "Claude usage endpoint answered \(code). Will retry.")
        }
        guard data.count <= 1_048_576 else { throw ProviderFailure(message: "Claude usage response was too large.") }
        let quotas = try QuotaParser.claudeUsage(data, maxAge: maxAge)
        guard !quotas.isEmpty else { throw ProviderFailure(message: "Claude usage endpoint reported no subscription quota.") }
        return quotas
    }
    private static func accessToken() throws -> String {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { throw ProviderFailure(message: "Could not run the security tool to read Claude Code's sign-in.") }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        switch process.terminationStatus {
        case 0: break
        case 44: throw ProviderFailure(message: "No Claude Code sign-in found. Run claude and log in, or use the bridge.")
        case 36, 128: throw KeychainDenied() // interaction not allowed / user cancelled an unlock prompt
        default: throw ProviderFailure(message: "Keychain read failed (security exited \(process.terminationStatus)).")
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = root["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else {
            throw ProviderFailure(message: "Claude Code's Keychain item did not hold a sign-in. Run claude and log in.")
        }
        if let expires = oauth["expiresAt"] as? NSNumber, Date(timeIntervalSince1970: expires.doubleValue / 1000) <= Date() {
            throw ProviderFailure(message: "Claude Code sign-in expired. Open Claude Code to refresh it.")
        }
        return token
    }
}

/// Scheduled polls stop after a denied prompt; the direct-poll toggle or the refresh button asks again.
struct KeychainDenied: LocalizedError {
    var errorDescription: String? { "Keychain access denied. Press refresh or re-enable direct polling to allow it." }
}

enum PowerState {
    /// Battery or Low Power Mode: poll less often. Unknown power sources count as mains.
    static var conserving: Bool {
        if ProcessInfo.processInfo.isLowPowerModeEnabled { return true }
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeRetainedValue() else { return false }
        return (type as String) == kIOPMBatteryPowerKey
    }
}
