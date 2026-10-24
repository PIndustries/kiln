import Foundation
import Crypto
import KilnKit
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

extension KilnCommands {
    private func terminalThemeURL() throws -> URL {
        guard isAuthorized() else { throw KilnError.message("Identity revoked or unauthorized") }
        // Include the canonical key: a revoked key's replacement cannot inherit its preferences.
        let owner = (principal?.name ?? "local-console") + ":" + (principal?.publicKey ?? "local-console")
        let digest = SHA256.hash(data: Data(owner.utf8)).map { String(format: "%02x", $0) }.joined()
        return terminalPreferencesDirectory.appendingPathComponent(digest + ".json")
    }
    public func terminalTheme() throws -> TerminalTheme {
        let url = try terminalThemeURL()
        let fd = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else {
            if errno == ENOENT { return TerminalTheme() }
            throw KilnError.message("Cannot read saved theme")
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= 4096 else {
            throw KilnError.message("Invalid saved theme file")
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        let data = try handle.read(upToCount: 4097) ?? Data()
        guard data.count <= 4096 else { throw KilnError.message("Saved theme exceeds size limit") }
        return try JSONDecoder().decode(TerminalTheme.self, from: data)
    }
    func terminalThemeCommand(_ parts: [String]) throws -> CommandResult {
        let args = Array(parts.dropFirst())
        if args.isEmpty {
            let theme = try terminalTheme()
            return CommandResult("Saved theme: accent \(theme.accent), background \(theme.background), text \(theme.foreground), muted \(theme.muted).\nUse theme green|cyan|amber|mono|default or theme custom <accent> <background> <text> <muted> (four distinct ANSI 0...255).", terminalTheme: theme)
        }
        guard let theme = TerminalTheme.parse(args) else { return CommandResult("Invalid theme. Use green, cyan, amber, mono, default, or custom with four distinct ANSI colors (0...255).", status: 2) }
        let url = try terminalThemeURL()
        try FileManager.default.createDirectory(at: terminalPreferencesDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try KilnStateFile.write(JSONEncoder().encode(theme), to: url)
        return CommandResult("Theme saved for your SSH identity and key; restored on reconnect and restart.", terminalTheme: theme)
    }
}
