import KilnWeb

struct HomeController {
    static func index(_ request: WebRequest) -> WebResponse {
        .view(HomePage(csrf: request.session.csrfToken))
    }

    static func greet(_ request: WebRequest) throws -> WebResponse {
        try greeting(name: request.form()["name"] ?? "friend", current: "")
    }

    static func hello(_ request: WebRequest) throws -> WebResponse {
        try greeting(name: request.parameters["name"] ?? "friend", current: "/hello/friend")
    }

    private static func greeting(name: String, current: String) throws -> WebResponse {
        // The HTML template and native Swift layout compose through typed HTML.
        let content = try AppTemplates.render("Home/greeting", values: ["name": .text(name)])
        return .view(PageLayout(title: "Greeting", current: current, content: content))
    }
}
