public import Shader

extension Shader.Compiler {
    /// A generated Swift file that carries kernels' text, and says in its first line what it is made from:
    ///
    ///     // institute shader: Picture Shader, Picture.Renderer.Metal.kernels, Metal && canImport(Metal)
    ///
    /// the target, the static constant the text is bound to, and the condition it is compiled under, if any.
    public struct File: Sendable, Hashable {
        public var target: String
        public var constant: String
        public var condition: String?

        public init(target: String, constant: String, condition: String? = nil) {
            self.target = target
            self.constant = constant
            self.condition = condition
        }
    }
}

extension Shader.Compiler.File {
    private static let mark = "// institute shader: "

    /// What a file says it is made from, or nil when it is not a generated one.
    public init?(reading contents: String) {
        guard let line = contents.split(separator: "\n", maxSplits: 1).first, line.hasPrefix(Self.mark) else { return nil }
        let parts = line.dropFirst(Self.mark.count).split(separator: ",", maxSplits: 2).map { part in
            String(part.drop { $0 == " " })
        }
        guard parts.count >= 2, parts[1].contains(".") else { return nil }
        self.init(target: parts[0], constant: parts[1], condition: parts.count == 3 ? parts[2] : nil)
    }

    /// The file's contents, carrying a text.
    public func contents(_ text: String) -> String {
        let path = constant.split(separator: ".")
        let holder = path.dropLast().joined(separator: ".")
        let name = path.last.map(String.init) ?? constant
        let indent = condition == nil ? "" : "    "
        let module = path.first.map(String.init) ?? constant
        var lines = [Self.mark + [target, constant, condition].compactMap { $0 }.joined(separator: ", ")]
        if let condition { lines.append("#if \(condition)") }
        lines += ["\(indent)import \(module)", "", "\(indent)extension \(holder) {"]
        lines += ["\(indent)    /// The kernels of \(target) in Metal's shading language.", "\(indent)    package static let \(name) = #\"\"\""]
        lines += text.split(separator: "\n", omittingEmptySubsequences: false).map { $0.isEmpty ? "" : "\(indent)        \($0)" }
        lines += ["\(indent)        \"\"\"#", "\(indent)}"]
        if condition != nil { lines.append("#endif") }
        return lines.joined(separator: "\n") + "\n"
    }
}
