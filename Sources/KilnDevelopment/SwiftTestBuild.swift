import Foundation
import KilnKit
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

extension WebIsolation {
    /// The trusted helper compiles the application as an importable module with
    /// its entry point renamed. Only the generated Swift Testing runner executes.
    static func buildTests(sdk: WebBuildSDK, root: URL, snapshot: WebFiles, applicationSources: [String]) throws -> Never {
        guard let testing = sdk.testArguments else { throw KilnError.message("Export a testing-capable SDK first") }
        var common: [String] = [], index = 0
        while index < sdk.arguments.count {
            if sdk.arguments[index] == "-module-name" { index += 2 }
            else { common.append(sdk.arguments[index]); index += 1 }
        }
        let prefix = ["/usr/bin/sandbox-exec","-p",buildProfile(sdk:sdk,job:root.path),sdk.compiler]
        let cache = ["-module-cache-path",root.appendingPathComponent("cache").path]
        let app = Process(); app.executableURL = URL(fileURLWithPath:prefix[0])
        app.arguments = Array(prefix.dropFirst()) + common + cache + ["-module-name","KilnApplication","-enable-testing","-whole-module-optimization","-emit-object","-emit-module","-emit-module-path",root.appendingPathComponent("KilnApplication.swiftmodule").path,"-Xfrontend","-entry-point-function-name","-Xfrontend","kiln_application_main"] + applicationSources + ["-o",root.appendingPathComponent("Application.o").path]
        try KilnStateFile.write(Data("Compiling application module".utf8),to:root.appendingPathComponent("phase.txt"))
        try app.run(); app.waitUntilExit()
        guard app.terminationStatus == 0 else { throw KilnError.message("Application test compilation failed") }
        let plan = try JSONDecoder().decode(SwiftTestPlan.self,from:Data(contentsOf:root.appendingPathComponent("TestPlan.json")))
        if plan.moduleOnly == true { exit(0) }
        let runner = root.appendingPathComponent("TestRunner.swift")
        try KilnStateFile.write(Data("import Testing\n@main struct KilnTestRunner { static func main() async { await Testing.__swiftPMEntryPoint() as Never } }\n".utf8),to:runner)
        let sources = snapshot.files.keys.filter { $0.hasPrefix("Tests/") && $0.hasSuffix(".swift") }.sorted().map { root.appendingPathComponent("Sources/"+$0).path }
        try KilnStateFile.write(Data("Compiling Swift tests".utf8),to:root.appendingPathComponent("phase.txt"))
        try replace(arguments:prefix + common + testing + cache + ["-module-name","KilnApplicationTests","-I",root.path] + sources + [runner.path,root.appendingPathComponent("Application.o").path] + sdk.objects + ["-o",root.appendingPathComponent("tests").path])
    }
}
