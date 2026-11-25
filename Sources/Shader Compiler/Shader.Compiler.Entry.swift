internal import Shader
internal import W3C_WebAssembly

extension Shader.Compiler {
    /// An exported function the text must offer.
    struct Entry {
        enum Kind {
            case kernel
            case function
        }

        var kind: Kind
        var name: String
        var index: Int
    }
}

extension Shader.Compiler.Entry {
    /// The module's entries, by name.
    static func entries(of module: W3C.WebAssembly.Module) throws(Shader.Compiler.Error) -> [Self] {
        var entries: [Self] = []
        for export in module.exports where export.kind == .function {
            for (prefix, kind) in [("kernel_", Kind.kernel), ("function_", Kind.function)] where export.name.hasPrefix(prefix) {
                let entry = Self(kind: kind, name: String(export.name.dropFirst(prefix.count)), index: export.index)
                if kind == .kernel, module.signature(of: entry.index) != .init(parameters: [.i32, .i32], results: []) {
                    throw .signature(entry: export.name)
                }
                entries.append(entry)
            }
        }
        guard !entries.isEmpty else { throw .entries }
        return entries.sorted { $0.name < $1.name }
    }
}
