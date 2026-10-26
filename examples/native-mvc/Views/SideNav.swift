import KilnWeb

struct SiteNavigation: View {
    let current: String
    var body: some View {
        Aside {
            Span("P.INDUSTRIES · WEB").cssClass("sidenav__brand")
            Nav {
                SiteLink(label: "Home", href: "/", current: current)
                SiteLink(label: "Live demo", href: "/counter", current: current)
                SiteLink(label: "Greeting", href: "/hello/friend", current: current)
            }.aria("label", "Main navigation")
        }.cssClass("sidenav").aria("label", "Site navigation")
    }
}

struct SiteLink: View {
    let label: String
    let href: String
    let current: String
    var body: some View {
        if href == current { Link(label, href: href).aria("current", "page") }
        else { Link(label, href: href) }
    }
}
