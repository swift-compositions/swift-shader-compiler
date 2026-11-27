internal import Shader
internal import W3C_WebAssembly

extension Shader.Compiler {
    /// An exported function the text must offer.
    struct Entry {
        enum Kind {
            case kernel
            case function
            case vertex
            case fragment
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
            let kinds = [("kernel_", Kind.kernel), ("function_", Kind.function), ("vertex_", Kind.vertex), ("fragment_", Kind.fragment)]
            for (prefix, kind) in kinds where export.name.hasPrefix(prefix) {
                let entry = Self(kind: kind, name: String(export.name.dropFirst(prefix.count)), index: export.index)
                let wanted: W3C.WebAssembly.Signature? =
                    switch kind {
                    case .kernel, .vertex: .init(parameters: [.i32, .i32], results: [])
                    case .fragment: .init(parameters: [.f32, .f32], results: [])
                    case .function: nil
                    }
                if let wanted, module.signature(of: entry.index) != wanted {
                    throw .signature(entry: export.name)
                }
                entries.append(entry)
            }
        }
        guard !entries.isEmpty else { throw .entries }
        return entries.sorted { ($0.name, $0.kind.order) < ($1.name, $1.kind.order) }
    }
}

extension Shader.Compiler.Entry {
    /// The entry's name with its kind before it, as the module exports it.
    var exported: String {
        switch kind {
        case .kernel: "kernel_\(name)"
        case .function: "function_\(name)"
        case .vertex: "vertex_\(name)"
        case .fragment: "fragment_\(name)"
        }
    }

    /// Whether the entry is a stage that draws.
    var draws: Bool { kind == .vertex || kind == .fragment }
}

extension Shader.Compiler.Entry.Kind {
    var order: Int {
        switch self {
        case .kernel: 0
        case .function: 1
        case .vertex: 2
        case .fragment: 3
        }
    }
}
