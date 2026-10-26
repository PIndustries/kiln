import Foundation

/// Server-rendered web views. This API resembles SwiftUI's composition syntax,
/// but produces HTML/CSS and shares KilnWeb's existing live transport.
public protocol View: Sendable {
    associatedtype Body: View
    @ViewBuilder var body: Body { get }
    func render() -> HTML
}
public extension View { func render() -> HTML { body.render() } }
extension HTML: View {
    public var body: HTML { self }
    public func render() -> HTML { self }
}

@resultBuilder public enum ViewBuilder {
    public static func buildExpression<V: View>(_ value: V) -> HTML { value.render() }
    public static func buildBlock(_ values: HTML...) -> HTML { .join(values) }
    public static func buildOptional(_ value: HTML?) -> HTML { value ?? "" }
    public static func buildEither(first: HTML) -> HTML { first }
    public static func buildEither(second: HTML) -> HTML { second }
    public static func buildArray(_ values: [HTML]) -> HTML { .join(values) }
    public static func buildLimitedAvailability(_ value: HTML) -> HTML { value }
}

/// Text always escapes data; trusted HTML literals can be composed explicitly.
public func Text(_ value: String) -> HTML { "\(value)" }

public struct Element: View {
    public enum Tag: String, Sendable {
        case html, head, body, title, meta, link, div, main, header, footer, nav, aside
        case h1, h2, h3, p, span, strong, a, section, form, label, input, button, br, ul, li
        var isVoid: Bool { [.meta,.link,.input,.br].contains(self) }
    }
    public enum Attribute: String, Sendable {
        case id, title, href, rel, name, value, type, action, method, role, required, disabled
        case lang, charset, content, placeholder, autocomplete, min, max
        case maxlength, checked, selected
        case labelFor = "for"
    }
    private let tag: Tag
    private var attributes: [String:String]
    private let content: HTML
    public init(_ tag: Tag, @ViewBuilder content: () -> HTML = { "" }) {
        self.tag = tag; self.content = content(); self.attributes = [:]
    }
    public var body: HTML {
        let attrs = attributes.keys.sorted().map { " \($0)=\"\(HTML.escape(attributes[$0]!))\"" }.joined()
        return HTML(stringLiteral:"<\(tag.rawValue)\(attrs)>"+(tag.isVoid ? "" : content.rendered+"</\(tag.rawValue)>"))
    }
    public func attribute(_ name: Attribute, _ value: String) -> Self {
        var copy = self; copy.attributes[name.rawValue] = value; return copy
    }
    public func id(_ value: String) -> Self { attribute(.id,value) }
    public func cssClass(_ value: String) -> Self {
        var copy = self; copy.attributes["class"] = [copy.attributes["class"],value].compactMap{$0}.joined(separator:" "); return copy
    }
    /// CSS is application-controlled, as with an external stylesheet. Values are
    /// escaped for the attribute context; never construct CSS from untrusted data.
    public func style(_ value: String) -> Self {
        var copy = self; copy.attributes["style"] = (copy.attributes["style"].map{$0+";"} ?? "")+value; return copy
    }
    public func padding(_ pixels: Int) -> Self { style("padding:\(pixels)px") }
    public func background(_ css: String) -> Self { style("background:\(css)") }
    public func foreground(_ css: String) -> Self { style("color:\(css)") }
    public func data(_ name: String, _ value: String) -> Self { named("data-",name,value) }
    public func aria(_ name: String, _ value: String) -> Self { named("aria-",name,value) }
    private func named(_ prefix: String, _ name: String, _ value: String) -> Self {
        precondition(!name.isEmpty && name.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 },"Attribute suffix must be a developer-defined lowercase name")
        var copy = self; copy.attributes[prefix+name] = value; return copy
    }
    public func onClick(_ event: String) -> Self { data("kiln-click",event) }
    public func onSubmit(_ event: String) -> Self { data("kiln-submit",event) }
}

public func H1(_ value: String) -> Element { Element(.h1) { Text(value) } }
public func H1(@ViewBuilder content: () -> HTML) -> Element { Element(.h1,content:content) }
public func H2(_ value: String) -> Element { Element(.h2) { Text(value) } }
public func Paragraph(_ value: String) -> Element { Element(.p) { Text(value) } }
public func Paragraph(@ViewBuilder content: () -> HTML) -> Element { Element(.p,content:content) }
public func Span(_ value: String) -> Element { Element(.span) { Text(value) } }
public func Strong(_ value: String) -> Element { Element(.strong) { Text(value) } }
public func Link(_ label: String, href: String) -> Element { Element(.a) { Text(label) }.attribute(.href,href) }
public func Button(_ label: String) -> Element { Element(.button) { Text(label) } }
public func Input(name: String, type: String = "text", value: String? = nil) -> Element {
    let input = Element(.input).attribute(.name,name).attribute(.type,type)
    return value.map { input.attribute(.value,$0) } ?? input
}
public func Label(_ title: String, for field: String) -> Element { Element(.label) { Text(title) }.attribute(.labelFor,field) }
public func Section(@ViewBuilder content: () -> HTML) -> Element { Element(.section,content:content) }
public func Header(@ViewBuilder content: () -> HTML) -> Element { Element(.header,content:content) }
public func Footer(_ value: String) -> Element { Element(.footer) { Text(value) } }
public func Main(@ViewBuilder content: () -> HTML) -> Element { Element(.main,content:content) }
public func Nav(@ViewBuilder content: () -> HTML) -> Element { Element(.nav,content:content) }
public func Aside(@ViewBuilder content: () -> HTML) -> Element { Element(.aside,content:content) }
public func Form(action: String? = nil, method: String = "post", @ViewBuilder content: () -> HTML) -> Element {
    let form = Element(.form,content:content).attribute(.method,method)
    return action.map { form.attribute(.action,$0) } ?? form
}
public func VStack(spacing: Int = 0, @ViewBuilder content: () -> HTML) -> Element {
    Element(.div,content:content).cssClass("kiln-vstack").style("display:flex;flex-direction:column;gap:\(spacing)px")
}
public func HStack(spacing: Int = 0, @ViewBuilder content: () -> HTML) -> Element {
    Element(.div,content:content).cssClass("kiln-hstack").style("display:flex;flex-direction:row;gap:\(spacing)px")
}
public func Document(title: String, stylesheet: String = "/assets/app.css", head: HTML = "", @ViewBuilder content: () -> HTML) -> HTML {
    let document = Element(.html) {
        Element(.head) {
            Element(.meta).attribute(.charset,"utf-8")
            Element(.meta).attribute(.name,"viewport").attribute(.content,"width=device-width,initial-scale=1")
            Element(.title) { Text(title) }
            Element(.link).attribute(.rel,"stylesheet").attribute(.href,stylesheet)
            head
        }
        Element(.body,content:content)
    }.attribute(.lang,"en")
    return .join(["<!doctype html>",document.render()])
}
public extension WebResponse {
    static func view<V: View>(_ view: V, status: Int = 200) -> Self { .html(view.render(),status:status) }
}

/// Template data is escaped by default. Only an explicit typed fragment may
/// insert composed markup, and fragments are refused inside attribute values.
public enum TemplateValue: Sendable {
    case text(String)
    case view(HTML)
    public func render() -> HTML {
        switch self { case .text(let value): Text(value); case .view(let html): html }
    }
    public func attribute() throws -> HTML {
        guard case .text(let value) = self else { throw TemplateValueError.fragmentInAttribute }
        return Text(value)
    }
}
public enum TemplateValueError: Error, Sendable { case fragmentInAttribute }
