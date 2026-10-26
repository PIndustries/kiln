import Foundation
import KilnKit

/// Embed registered Views/*.html into the isolated Swift build. Templates are
/// compiled data, never runtime filesystem reads or executable template code.
enum WebTemplateCompiler {
    static func write(_ files: [String:Data], at root: URL) throws -> URL? {
        let templates = files.keys.filter { $0.hasPrefix("Views/") && $0.hasSuffix(".html") }.sorted()
        guard !templates.isEmpty else { return nil }
        let token = try NSRegularExpression(pattern:#"\{\{\s*([A-Za-z][A-Za-z0-9_]*)\s*\}\}"#)
        func literal(_ value: String) throws -> String {
            let escaped = value.unicodeScalars.map { scalar -> String in
                switch scalar.value {
                case 34: return "\\\""
                case 92: return "\\\\"
                case 10: return "\\n"
                case 13: return "\\r"
                case 9: return "\\t"
                case 0...31, 127: return "\\u{"+String(scalar.value,radix:16)+"}"
                default: return String(scalar)
                }
            }.joined()
            return "\""+escaped+"\""
        }
        var cases: [String] = []
        for path in templates {
            guard let bytes = files[path], let source = String(data:bytes,encoding:.utf8) else { throw KilnError.message("Template must be UTF-8: "+path) }
            let matches = token.matches(in:source,range:NSRange(source.startIndex...,in:source))
            let stripped = token.stringByReplacingMatches(in:source,range:NSRange(source.startIndex...,in:source),withTemplate:"")
            guard !stripped.contains("{{"), !stripped.contains("}}") else { throw KilnError.message("Invalid template placeholder in "+path) }
            let scripts = try NSRegularExpression(pattern:#"<(script|style)\b[^>]*>.*?</\1\s*>"#,options:[.caseInsensitive,.dotMatchesLineSeparators])
            for match in scripts.matches(in:source,range:NSRange(source.startIndex...,in:source)) {
                guard !matches.contains(where:{ NSIntersectionRange($0.range,match.range).length > 0 }) else { throw KilnError.message("Template slots cannot appear in script/style content: "+path) }
            }
            var pieces: [String] = [], keys = Set<String>(), start = source.startIndex
            for match in matches {
                let range = Range(match.range,in:source)!, key = String(source[Range(match.range(at:1),in:source)!])
                pieces.append("HTML(stringLiteral: \(try literal(String(source[start..<range.lowerBound]))))")
                var inTag = false, quote: Character?
                for char in source[..<range.lowerBound] {
                    if let active = quote { if char == active { quote = nil } }
                    else if inTag, char == "\"" || char == "'" { quote = char }
                    else if char == "<" { inTag = true }
                    else if char == ">" { inTag = false }
                }
                guard !inTag || quote != nil else { throw KilnError.message("Template slots inside tags require a quoted attribute: "+path) }
                if inTag {
                    let prefix = String(source[..<range.lowerBound])
                    let attr = try NSRegularExpression(pattern:#"([A-Za-z][A-Za-z0-9:_-]*)\s*=\s*["'][^"']*$"#)
                    if let found = attr.firstMatch(in:prefix,range:NSRange(prefix.startIndex...,in:prefix)), let nameRange = Range(found.range(at:1),in:prefix) {
                        let name = prefix[nameRange].lowercased()
                        guard name != "style", !name.hasPrefix("on") else { throw KilnError.message("Template slots cannot contain CSS or event-handler code: "+path) }
                    }
                }
                pieces.append((inTag ? "try " : "")+"values[\(try literal(key))]?."+(inTag ? "attribute()" : "render()")+" ?? \"\"")
                keys.insert(key); start = range.upperBound
            }
            pieces.append("HTML(stringLiteral: \(try literal(String(source[start...]))))")
            let name = String(path.dropFirst(6).dropLast(5))
            let required = try keys.sorted().map(literal).joined(separator:",")
            cases.append("case \(try literal(name)):\n guard Set<String>([\(required)]).isSubset(of:Set(values.keys)) else { throw ViewError.missingValue(name) }\n return HTML.join([\(pieces.joined(separator:","))])")
        }
        let source = """
        import Foundation
        import KilnWeb
        // Generated from registered Views/*.html. Edit those template files.
        enum AppTemplates {
            enum ViewError: Error { case unknownTemplate(String), missingValue(String) }
            static func render(_ name: String, values: [String:TemplateValue] = [:]) throws -> HTML {
                switch name {
                \(cases.joined(separator:"\n"))
                default: throw ViewError.unknownTemplate(name)
                }
            }
        }
        """
        let path = root.appendingPathComponent("GeneratedKilnViews.swift")
        try KilnStateFile.write(Data(source.utf8),to:path)
        return path
    }
}
