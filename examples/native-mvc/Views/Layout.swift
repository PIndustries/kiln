import KilnWeb

/// Theme colors and responsive behavior come from the shared CSS file.
struct PageLayout: View {
    let title: String
    let current: String
    let content: HTML

    var body: some View {
        Document(title: title) {
            Element(.div) {
                SiteNavigation(current: current)
                Main { content }
            }.cssClass("shell")
        }
    }
}
