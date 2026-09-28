import Foundation

/// Expand RFC 6570 level-3 scalar templates and OpenSearch optional parameters; omit undefined variables.
nonisolated enum OPDSURITemplate {
    static func isTemplated(_ template: String) -> Bool {
        guard let open = template.firstIndex(of: "{") else { return false }
        return template[open...].contains("}")
    }

    /// Return variable names in order, without operators or modifiers.
    static func variableNames(in template: String) -> [String] {
        var names: [String] = []
        for expression in expressions(in: template) {
            for spec in expression.specs where !names.contains(spec.name) {
                names.append(spec.name)
            }
        }
        return names
    }

    /// `nil` when the template is malformed. A variable the caller did not supply is simply omitted.
    static func expand(_ template: String, values: [String: String]) -> String? {
        var result = ""
        var index = template.startIndex

        while index < template.endIndex {
            guard let open = template[index...].firstIndex(of: "{") else {
                result += template[index...]
                return result
            }
            guard let close = template[open...].firstIndex(of: "}") else { return nil }

            result += template[index..<open]
            let body = String(template[template.index(after: open)..<close])
            guard let expression = Expression(body: body) else { return nil }
            result += expression.expanded(with: values)
            index = template.index(after: close)
        }

        return result
    }

    private struct VarSpec {
        let name: String
        /// A `:n` prefix modifier. `*` explodes a list, which OPDS never sends, so it is accepted and ignored.
        let prefixLength: Int?

        init?(_ raw: String) {
            var text = raw.trimmingCharacters(in: .whitespaces)
            // OpenSearch marks an optional parameter with a trailing `?`, which RFC 6570 does not define.
            if text.hasSuffix("?") { text.removeLast() }
            if text.hasSuffix("*") { text.removeLast() }

            var length: Int?
            if let colon = text.lastIndex(of: ":"), text.distance(from: colon, to: text.endIndex) <= 5 {
                let digits = text[text.index(after: colon)...]
                if !digits.isEmpty, digits.allSatisfy(\.isNumber), let parsed = Int(digits) {
                    length = parsed
                    text = String(text[text.startIndex..<colon])
                }
            }

            guard !text.isEmpty else { return nil }
            name = text
            prefixLength = length
        }
    }

    private struct Expression {
        let `operator`: Character?
        let specs: [VarSpec]

        init?(body: String) {
            guard !body.isEmpty else { return nil }
            var remainder = Substring(body)
            if let first = remainder.first, "+#./;?&=,!@|".contains(first) {
                `operator` = first
                remainder = remainder.dropFirst()
            } else {
                `operator` = nil
            }
            let parsed = remainder.split(separator: ",").compactMap { VarSpec(String($0)) }
            guard !parsed.isEmpty else { return nil }
            specs = parsed
        }

        func expanded(with values: [String: String]) -> String {
            let defined = specs.compactMap { spec -> (VarSpec, String)? in
                guard let value = value(for: spec.name, in: values) else { return nil }
                guard let length = spec.prefixLength else { return (spec, value) }
                return (spec, String(value.prefix(length)))
            }
            guard !defined.isEmpty else { return "" }

            switch `operator` {
            case "?", "&":
                let pairs = defined.map { "\($0.0.name)=\(encode($0.1))" }
                return "\(`operator` == "?" ? "?" : "&")\(pairs.joined(separator: "&"))"
            case ";":
                return defined.map { $0.1.isEmpty ? ";\($0.0.name)" : ";\($0.0.name)=\(encode($0.1))" }.joined()
            case ".", "/":
                return defined.map { "\(`operator`!)\(encode($0.1))" }.joined()
            case "#":
                return "#" + defined.map { encodeReserved($0.1) }.joined(separator: ",")
            case "+":
                return defined.map { encodeReserved($0.1) }.joined(separator: ",")
            default:
                return defined.map { encode($0.1) }.joined(separator: ",")
            }
        }

        /// OpenSearch parameters may be namespace-qualified; callers provide the local name.
        private func value(for name: String, in values: [String: String]) -> String? {
            if let direct = values[name] { return direct }
            guard let colon = name.lastIndex(of: ":") else { return nil }
            return values[String(name[name.index(after: colon)...])]
        }
    }

    private static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
    }

    private static func encodeReserved(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: unreservedAndReserved) ?? value
    }

    private static let unreserved: CharacterSet = {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return allowed
    }()

    private static let unreservedAndReserved: CharacterSet = {
        var allowed = unreserved
        allowed.insert(charactersIn: ":/?#[]@!$&'()*+,;=%")
        return allowed
    }()

    private static func expressions(in template: String) -> [Expression] {
        var found: [Expression] = []
        var index = template.startIndex
        while let open = template[index...].firstIndex(of: "{"),
            let close = template[open...].firstIndex(of: "}")
        {
            if let expression = Expression(body: String(template[template.index(after: open)..<close])) {
                found.append(expression)
            }
            index = template.index(after: close)
        }
        return found
    }
}
