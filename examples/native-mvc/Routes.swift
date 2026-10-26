import Foundation
import KilnWeb

enum Routes {
    static func make(hub: LiveHub, model: CounterModel) throws -> WebRouter {
        var router = WebRouter()
        try router.on("GET", "/", action: HomeController.index)
        try router.on("POST", "/greet", action: HomeController.greet)
        try router.on("GET", "/hello/:name", action: HomeController.hello)
        try router.on("POST", "/counter/increment") { _ in
            await model.increment()
            await hub.publish("counter")
            return try .json(["updated": true])
        }
        try router.on("GET", "/health") { _ in try .json(["status": "ok"]) }
        try router.on("GET", "/assets/app.css") { _ in
            .init(contentType: "text/css; charset=utf-8", body: Data(ExampleWeb.css.utf8))
        }
        try router.live("/counter", topics: ["counter"]) { _ in
            CounterController(model: model, hub: hub)
        }
        return router
    }
}
