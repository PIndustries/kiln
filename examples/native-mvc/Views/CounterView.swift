import KilnWeb

/// Pure value view: no requests, network operations or mutable application state.
struct CounterPage: View {
    let count: Int
    let note: String
    var body: some View {
        Header {
            Span("KILN / LIVE WEB")
            Link("Framework home", href: "/")
        }
        H1 {
            Text("Built with Kiln AI.")
            Element(.br)
            Text("Live on your Mac.")
        }
        Paragraph("Open this page in two tabs. Every change travels through a Swift server action and broadcasts to connected views.")
        Section {
            SectionTitle(text: "SHARED COUNTER")
            Strong(String(count)).id("count")
            Button("Increment on server ↗").id("increment").onClick("increment")
        }
        Section {
            SectionTitle(text: "LIVE MESSAGE")
            Paragraph(note).id("note")
            Form {
                Label("Update the shared message", for: "message")
                Input(name: "message").id("message").attribute(.maxlength, "120").attribute(.required, "")
                Button("Broadcast update")
            }.onSubmit("rename")
        }
        Footer("Swift controllers · escaped HTML · WebSocket events · application-local pub/sub")
    }
}
