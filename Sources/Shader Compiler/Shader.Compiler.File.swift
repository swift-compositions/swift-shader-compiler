public import Shader

extension Shader.Compiler {
    /// A generated Swift file that carries kernels' text, and says in its first line what it is made from:
    ///
    ///     // institute shader: Picture Shader, Picture.Renderer.Metal.kernels, Metal && canImport(Metal)
    ///     // institute shader (WGSL): Picture Shader, Picture.Renderer.WebGPU.kernels
    ///
    /// the language when it is not Metal's, the target, the static constant the text is bound to, and the condition
    /// it is compiled under, if any. Metal's text is one string; WGSL's is a module for each kernel, by its name.
    public struct File: Sendable, Hashable {
        public var language: Language
        public var target: String
        public var constant: String
        public var condition: String?

        public init(language: Language = .metal, target: String, constant: String, condition: String? = nil) {
            self.language = language
            self.target = target
            self.constant = constant
            self.condition = condition
        }
    }
}

extension Shader.Compiler.File {
    /// A GPU's language a file carries kernels in.
    public enum Language: String, Sendable, Hashable, CaseIterable {
        case metal = "Metal"
        case wgsl = "WGSL"

        /// What the file's documentation calls it.
        var name: String {
            switch self {
            case .metal: "Metal's shading language"
            case .wgsl: "WGSL, each kernel a module of its own by its name"
            }
        }
    }
}

extension Shader.Compiler.File {
    private static let mark = "// institute shader"

    /// What a file says it is made from, or nil when it is not a generated one.
    public init?(reading contents: String) {
        guard let line = contents.split(separator: "\n", maxSplits: 1).first, line.hasPrefix(Self.mark) else { return nil }
        var rest = line.dropFirst(Self.mark.count)
        var language = Language.metal
        if rest.hasPrefix(" (") {
            guard let close = rest.firstIndex(of: ")"), let named = Language(rawValue: String(rest[rest.index(rest.startIndex, offsetBy: 2)..<close])) else {
                return nil
            }
            language = named
            rest = rest[rest.index(after: close)...]
        }
        guard rest.hasPrefix(": ") else { return nil }
        let parts = rest.dropFirst(2).split(separator: ",", maxSplits: 2).map { part in
            String(part.drop { $0 == " " })
        }
        guard parts.count >= 2, parts[1].contains(".") else { return nil }
        self.init(language: language, target: parts[0], constant: parts[1], condition: parts.count == 3 ? parts[2] : nil)
    }

    /// The file's contents, carrying Metal's text.
    public func contents(_ text: String) -> String {
        contents(type: nil) { indent in
            ["\(indent)    package static let \(name) = #\"\"\""] + Self.lines(text, "\(indent)        ") + ["\(indent)        \"\"\"#"]
        }
    }

    /// The file's contents, carrying WGSL's modules, by kernel.
    public func contents(_ texts: [String: String]) -> String {
        contents(type: "[Swift.String: Swift.String]") { indent in
            var lines = ["\(indent)    package static let \(name): [Swift.String: Swift.String] = ["]
            for (kernel, text) in texts.sorted(by: { $0.key < $1.key }) {
                lines += ["\(indent)        \"\(kernel)\": #\"\"\""] + Self.lines(text, "\(indent)            ") + ["\(indent)            \"\"\"#,"]
            }
            return lines + ["\(indent)    ]"]
        }
    }

    private var name: String { constant.split(separator: ".").last.map(String.init) ?? constant }

    private static func lines(_ text: String, _ indent: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { $0.isEmpty ? "" : "\(indent)\($0)" }
    }

    private func contents(type: String?, _ body: (String) -> [String]) -> String {
        let path = constant.split(separator: ".")
        let holder = path.dropLast().joined(separator: ".")
        let indent = condition == nil ? "" : "    "
        let module = path.first.map(String.init) ?? constant
        let label = language == .metal ? "" : " (\(language.rawValue))"
        var lines = [Self.mark + label + ": " + [target, constant, condition].compactMap { $0 }.joined(separator: ", ")]
        if let condition { lines.append("#if \(condition)") }
        lines += ["\(indent)import \(module)", "", "\(indent)extension \(holder) {"]
        lines += ["\(indent)    /// The kernels of \(target) in \(language.name)."]
        lines += body(indent)
        lines.append("\(indent)}")
        if condition != nil { lines.append("#endif") }
        return lines.joined(separator: "\n") + "\n"
    }
}
