import KilnWeb

struct HomePage: View {
    let csrf: String
    var body: some View {
        PageLayout(title: "Kiln Web", current: "/", content: HomeContent(csrf: csrf).render())
    }
}

struct HomeContent: View {
    let csrf: String
    var body: some View {
        Header { Span("KILN / WEB FRAMEWORK") }
        H1("Hello from P.Industries")
        Paragraph("A native HTTP and live-view foundation for independently deployed Kiln applications.")
        Link("Open the live demo ↗", href: "/counter").cssClass("button")
        H2("Controller and form action").style("scroll-margin-top:24px")
        Form(action: "/greet") {
            Input(name: "_csrf", type: "hidden", value: csrf)
            Label("Your name", for: "name")
            Input(name: "name").id("name").attribute(.required, "")
            Button("Render greeting")
        }
    }
}
