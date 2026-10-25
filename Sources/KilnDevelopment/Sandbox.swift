import Foundation
import Crypto
import KilnKit
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public struct WebBuildSDK: Codable, Sendable {
    public let schemaVersion: Int
    public let compiler: String
    public let arguments: [String]
    public let objects: [String]
    public let readRoots: [String]
    public let runtimeLibraries: [String]
    public let builder: String
    public let launcher: String
    public let inputDigests: [String: String]
    public func validate() throws {
        guard inputDigests.count <= 4096, !inputDigests.isEmpty, schemaVersion == 1, arguments.count <= 256, !objects.isEmpty, objects.count <= 2048,
              readRoots.count <= 16, runtimeLibraries.count <= 4,
              [compiler, builder, launcher].allSatisfy({ $0.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: $0) }),
              (readRoots + runtimeLibraries + objects).allSatisfy({ $0.hasPrefix("/") && !$0.contains("\n") && !$0.contains("\0") }),
              arguments.allSatisfy({ !$0.contains("\0") && $0.utf8.count <= 4096 }) else { throw KilnError.message("Invalid trusted web SDK configuration") }
    }
    public func verifyInputs() throws {
        for (path, expected) in inputDigests {
            guard path.hasPrefix("/"), expected.count == 64,
                  let size = try FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber, size.intValue <= 134_217_728,
                  WebIsolation.digest(try Data(contentsOf: URL(fileURLWithPath: path))) == expected else {
                throw KilnError.message("Trusted SDK changed; export and register its updated revision first")
            }
        }
    }
}
public enum WebIsolation {
    public static var supported: Bool {
        #if os(macOS)
        FileManager.default.isExecutableFile(atPath: "/usr/bin/sandbox-exec")
        #else
        false
        #endif
    }
    public static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func quote(_ value: String) -> String { "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
    static func canonical(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return URL(fileURLWithPath: path).standardizedFileURL.path }
        defer { free(resolved) }
        return String(cString: resolved)
    }
    static func systemProfile() -> String {
        """
        (version 1)(deny default)
        (allow signal (target self))(allow sysctl-read)(allow file-read-metadata)
        (allow mach-lookup (global-name "com.apple.system.logger"))
        (allow file-read* (literal "/") (subpath "/System") (subpath "/usr/lib") (subpath "/usr/share")
          (subpath "/private/var/db/dyld") (literal "/dev/null") (literal "/dev/random") (literal "/dev/urandom"))
        """
    }
    static func buildProfile(sdk: WebBuildSDK, job: String) -> String {
        let compilerRoot = URL(fileURLWithPath: canonical(sdk.compiler)).deletingLastPathComponent().path
        // A standalone Swift toolchain can delegate linking to Xcode's ld.
        // Keep execution restricted to installed toolchain binaries, not SDK
        // build objects or the edited source/job directory.
        let linkers = sdk.readRoots.filter { $0.hasPrefix("/Applications/") && $0.hasSuffix("/Contents") }.map {
            "(subpath \(quote(canonical($0 + "/Developer/Toolchains"))))"
        }.joined(separator: " ")
        let read = sdk.readRoots.map { "(subpath \(quote(canonical($0))))" }.joined(separator: " ")
        return systemProfile() + """
        \n(allow process-fork)
        (allow process-exec (subpath \(quote(compilerRoot))) (subpath "/usr/bin") \(linkers))
        (allow file-read* \(read))
        (allow file-read* file-write* (subpath \(quote(canonical(job)))))
        """
    }
    static func runtimeProfile(executable: String, data: String, port: Int, libraries: [String]) -> String {
        let libraries = libraries.map { "(subpath \(quote(canonical($0))))" }.joined(separator: " ")
        return systemProfile() + """
        \n(allow process-exec (literal \(quote(canonical(executable)))))
        (allow file-read* (literal \(quote(canonical(executable)))) \(libraries))
        (allow file-read* file-write* (subpath \(quote(canonical(data)))))
        (allow network-bind (local ip "localhost:\(port)"))
        (allow network-inbound (local ip "localhost:\(port)"))
        """
    }
    private static func replace(arguments: [String]) throws -> Never {
        var pointers = arguments.map { strdup($0) }; pointers.append(nil)
        defer { for pointer in pointers { free(pointer) } }
        execv(arguments[0], &pointers)
        throw KilnError.message("Isolated web process could not execute")
    }
    /// Trusted helper. Swift source is data to the compiler; no shell, SwiftPM
    /// manifests, package plugins, dependency fetching or user environment runs.
    public static func build(job: String) throws -> Never {
        guard supported else { throw KilnError.message("Isolated web builds are currently available on macOS only") }
        let root = URL(fileURLWithPath: canonical(job))
        let sdk = try JSONDecoder().decode(WebBuildSDK.self, from: Data(contentsOf: root.appendingPathComponent("sdk.json")))
        try sdk.validate(); try sdk.verifyInputs()
        if getpgrp() != getpid(), setpgid(0, 0) != 0 { throw KilnError.message("Cannot establish build process group") }
        guard chdir(root.path) == 0 else { throw KilnError.message("Build workspace unavailable") }
        let environment = ["HOME": root.path, "TMPDIR": root.path + "/", "PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"]
        for key in ProcessInfo.processInfo.environment.keys { unsetenv(key) }
        for (key, value) in environment { setenv(key, value, 1) }
        let args = ["/usr/bin/sandbox-exec", "-p", buildProfile(sdk: sdk, job: root.path), sdk.compiler] + sdk.arguments +
            ["-module-cache-path", root.appendingPathComponent("cache").path, root.appendingPathComponent("App.swift").path] + sdk.objects +
            ["-o", root.appendingPathComponent("app").path]
        try replace(arguments: args)
    }
    /// Always-enforced launcher copied into each ordinary Kiln release. Older
    /// supervisors cannot silently ignore a new sandbox manifest field.
    public static func serve(arguments: [String]) throws -> Never {
        guard supported, arguments.count >= 3 else { throw KilnError.message("Isolated web previews require macOS") }
        let binary = canonical(arguments[0]), expected = arguments[1]
        guard expected.count == 64, expected.allSatisfy(\.isHexDigit),
              let rawPort = ProcessInfo.processInfo.environment["KILN_PORT"], let port = Int(rawPort), (1024...65535).contains(port),
              let data = ProcessInfo.processInfo.environment["KILN_DATA_DIR"] else { throw KilnError.message("Incomplete isolated preview environment") }
        let metadata = try FileManager.default.attributesOfItem(atPath: binary)
        guard ((metadata[.size] as? NSNumber)?.intValue ?? Int.max) <= 134_217_728,
              digest(try Data(contentsOf: URL(fileURLWithPath: binary))) == expected else { throw KilnError.message("Preview executable digest changed") }
        let libraries = try JSONDecoder().decode([String].self, from: Data(arguments[2].utf8))
        guard libraries.count <= 4, libraries.allSatisfy({ $0.hasPrefix("/") && !$0.contains("\0") }) else { throw KilnError.message("Invalid preview runtime libraries") }
        let profile = runtimeProfile(executable: binary, data: data, port: port, libraries: libraries)
        // Runtime receives only its app data, port and release identity. No HOME,
        // provider credentials, Vault grants, compiler paths or supervisor state.
        let allowed = Set(["KILN_DATA_DIR", "KILN_PORT", "KILN_APP_NAME", "KILN_RELEASE_VERSION"])
        for key in ProcessInfo.processInfo.environment.keys where !allowed.contains(key) { unsetenv(key) }
        setenv("HOME", data, 1); setenv("TMPDIR", data + "/", 1); setenv("PATH", "/usr/bin:/bin", 1)
        try replace(arguments: ["/usr/bin/sandbox-exec", "-p", profile, binary] + Array(arguments.dropFirst(3)))
    }
}
