import Foundation
import KilnWeb

@main struct ExampleWeb {
    static func main() throws {
        let args = CommandLine.arguments
        let port = ProcessInfo.processInfo.environment["KILN_PORT"].flatMap(Int.init) ?? args.firstIndex(of: "--port").flatMap { $0 + 1 < args.count ? Int(args[$0 + 1]) : nil } ?? 18082
        let origin = args.firstIndex(of: "--origin").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } ?? "http://127.0.0.1:\(port)"
        let hub = LiveHub(), model = CounterModel()
        let router = try Routes.make(hub: hub, model: model)
        let application = try WebApplication(
            router: router, origin: origin, hub: hub,
            healthAuthority: "127.0.0.1:\(port)",
            developmentReload: args.contains("--development"),
            layout: { page in
                Document(title: "Kiln Live Web", head: page.client) {
                    page.status
                    page.root
                }
            }
        )
        let server = try WebServer(application: application, port: port)
        print("Kiln Web demo: \(origin) (worker port \(server.port))")
        try server.wait()
    }
}
