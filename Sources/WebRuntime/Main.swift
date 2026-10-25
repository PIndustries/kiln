import Foundation
import KilnDevelopment
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
@main struct WebRuntime {
    static func main() {
        do { try WebIsolation.serve(arguments: Array(CommandLine.arguments.dropFirst())) }
        catch { FileHandle.standardError.write(Data("Isolated web preview failed.\n".utf8)); exit(1) }
    }
}
