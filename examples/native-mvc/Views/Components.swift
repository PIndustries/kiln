import KilnWeb

struct SectionTitle: View {
    let text: String
    var body: some View { Span(text).cssClass("label") }
}
