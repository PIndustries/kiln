import Foundation
import KilnDevelopment
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
@main struct WebBuilder {
    static func main() {
        do {
            guard CommandLine.arguments.count == 2 else { exit(2) }
            try WebIsolation.build(job: CommandLine.arguments[1])
        } catch { FileHandle.standardError.write(Data("Isolated web build failed.\n".utf8)); exit(1) }
    }
}
