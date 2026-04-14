import Foundation

/// Locates external CLI binaries (whisper-cli, llama-cli) that the app shells out to.
///
/// Resolution order:
///   1. Cached `brew --prefix <formula>` lookup (covers non-standard `HOMEBREW_PREFIX`).
///   2. Common install dirs (`/opt/homebrew/bin`, `/usr/local/bin`, `~/.local/bin`, `~/bin`).
///   3. The process `$PATH`.
///
/// When Voice is launched from Finder (Homebrew Cask or DMG install), `$PATH` is
/// minimal (usually `/usr/bin:/bin:/usr/sbin:/sbin`). The brew-prefix lookup is what
/// bridges that gap — it invokes `brew` directly from its absolute paths so the app
/// finds whisper.cpp / llama.cpp even without a login shell environment.
enum ToolDiscovery {
    /// Maps the CLI binary name to the Homebrew formula that ships it.
    static let formulaForBinary: [String: String] = [
        "whisper-cli": "whisper-cpp",
        "llama-cli": "llama.cpp",
    ]

    /// Returns the first existing executable for `name`, or nil if none found.
    static func findExecutable(named name: String) -> String? {
        for candidate in executableSearchCandidates(named: name) {
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    /// All candidate paths for `name`, in priority order, deduplicated.
    static func executableSearchCandidates(named name: String) -> [String] {
        var candidates: [String] = []

        if let formula = formulaForBinary[name],
           let prefix = brewPrefix(for: formula)
        {
            candidates.append("\(prefix)/bin/\(name)")
        }

        let commonDirectories = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            NSHomeDirectory() + "/.local/bin",
            NSHomeDirectory() + "/bin",
        ]

        let pathDirectories = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)

        candidates.append(contentsOf: (commonDirectories + pathDirectories).map { "\($0)/\(name)" })

        var seen: Set<String> = []
        return candidates.filter { seen.insert($0).inserted }
    }

    // MARK: - Homebrew prefix lookup

    nonisolated(unsafe) private static var brewPrefixCache: [String: String?] = [:]
    private static let brewPrefixCacheLock = NSLock()

    /// Runs `brew --prefix <formula>` with a short timeout and caches the result.
    /// Returns nil if brew is missing, the formula is not installed, or the call times out.
    static func brewPrefix(for formula: String) -> String? {
        brewPrefixCacheLock.lock()
        if let cached = brewPrefixCache[formula] {
            brewPrefixCacheLock.unlock()
            return cached
        }
        brewPrefixCacheLock.unlock()

        let resolved = resolveBrewPrefix(formula: formula)

        brewPrefixCacheLock.lock()
        brewPrefixCache[formula] = resolved
        brewPrefixCacheLock.unlock()

        return resolved
    }

    private static func resolveBrewPrefix(formula: String) -> String? {
        guard let brew = brewExecutable() else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: brew)
        process.arguments = ["--prefix", formula]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return nil
        }

        // Enforce a 2s ceiling — `brew --prefix` normally returns in tens of ms.
        let deadline = Date().addingTimeInterval(2.0)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }

        if process.isRunning {
            process.terminate()
            return nil
        }

        guard process.terminationStatus == 0 else { return nil }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let output, !output.isEmpty,
              FileManager.default.fileExists(atPath: output)
        else { return nil }

        return output
    }

    private static func brewExecutable() -> String? {
        let candidates = [
            "/opt/homebrew/bin/brew",
            "/usr/local/bin/brew",
            "/home/linuxbrew/.linuxbrew/bin/brew",
        ]

        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
    }
}
