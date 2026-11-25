internal import Byte
internal import Metal_Standard
internal import Shader
internal import W3C_WebAssembly

extension Shader.Compiler {
    /// A module being written.
    struct Unit {
        let module: W3C.WebAssembly.Module
        let entries: [Entry]
        /// The functions written so far, in the order they were reached.
        var written: [(index: Int, function: Metal.Function)] = []
        var uses: [Int: Use] = [:]
        /// How many bytes of stack a function and those it calls take.
        var depths: [Int: Int] = [:]
        var reaching: Set<Int> = []
        let image: Image

        init(module: W3C.WebAssembly.Module, entries: [Entry]) {
            self.module = module
            self.entries = entries
            image = Image(module)
        }
    }
}

extension Shader.Compiler.Unit {
    static let state = Metal.Expression.name("s")
    static let stateKind = Metal.Kind.reference(.structure("Shader_State"), .thread)

    /// A function's name in the text.
    static func name(_ index: Int) -> String { "shader_\(index)" }

    /// The value the stack starts from.
    var top: Int32 {
        guard case .i32(let value)? = module.globals.first?.initial.first else { return 0 }
        return value
    }

    /// Writes a function and all it reaches, callees first.
    private mutating func reach(_ index: Int) throws(Shader.Compiler.Error) {
        guard uses[index] == nil else { return }
        guard reaching.insert(index).inserted else { throw .recursion(function: index) }
        var body = Shader.Compiler.Body(module: module, index: index)
        let function = try body.function()
        var use = body.use
        var below = 0
        for callee in body.use.calls.sorted() {
            try reach(callee)
            if let its = uses[callee] { use.formUnion(its) }
            below = max(below, depths[callee] ?? 0)
        }
        uses[index] = use
        depths[index] = below + body.frame
        written.append((index, function))
        reaching.remove(index)
    }

    /// The whole text.
    mutating func source() throws(Shader.Compiler.Error) -> Metal.Source {
        for entry in entries { try reach(entry.index) }
        var all = Shader.Compiler.Use()
        for use in uses.values { all.formUnion(use) }
        let stack = entries.map { depths[$0.index] ?? 0 }.max() ?? 0
        let memory = Shader.Compiler.Memory(top: top, size: (stack + 3) & ~3, image: image)
        var items: [Metal.Source.Item] = [.structure(state(all, memory: memory))]
        if !image.words.isEmpty, !all.helpers.isDisjoint(with: Shader.Compiler.Helper.loading) { items.append(image.item) }
        items += Shader.Compiler.Helper.needed(by: all.helpers).map { .function($0.function(memory)) }
        items += written.map { .function($0.function) }
        for entry in entries {
            let use = uses[entry.index] ?? .init()
            items.append(.function(entry.kind == .kernel ? kernel(entry, use) : try function(entry, use)))
        }
        return Metal.Source(items)
    }

    private func state(_ use: Shader.Compiler.Use, memory: Shader.Compiler.Memory) -> Metal.Structure {
        var members: [Metal.Structure.Member] = []
        if memory.size > 0 { members.append(.init(.uint, "memory", count: memory.size / 4)) }
        members += module.globals.enumerated().map { place, global in
            .init(global.kind.value.metal ?? .uint, "g\(place)")
        }
        members += use.reads.sorted().map { .init(.pointer(.uint, .device, constant: true), "r\($0)") }
        members += use.writes.sorted().map { .init(.pointer(.uint, .device), "w\($0)") }
        members += use.results.sorted().map { .init(.float, "result\($0)") }
        return .init(name: "Shader_State", members: members)
    }

    /// The statements that make a state, with the buffers a kernel is handed.
    private func making(_ use: Shader.Compiler.Use) -> [Metal.Statement] {
        var statements: [Metal.Statement] = [.declare(.structure("Shader_State"), "s", nil)]
        for (place, global) in module.globals.enumerated() {
            let value: Metal.Expression
            switch global.initial.first {
            case .i32(let number): value = .convert(.int, [.uint(UInt32(bitPattern: number))])
            case .i64(let number): value = .convert(.long, [.ulong(UInt64(bitPattern: number))])
            case .f32(let bits): value = .float(bits)
            default: continue
            }
            statements.append(.assign(.member(Self.state, "g\(place)"), value))
        }
        statements += use.reads.sorted().map { .assign(.member(Self.state, "r\($0)"), .name("b\($0)")) }
        statements += use.writes.sorted().map { .assign(.member(Self.state, "w\($0)"), .name("b\($0)")) }
        return statements
    }

    private func kernel(_ entry: Shader.Compiler.Entry, _ use: Shader.Compiler.Use) -> Metal.Function {
        let parameters: [Metal.Function.Parameter] =
            use.reads.union(use.writes).sorted().map { index in
                .init(.pointer(.uint, .device, constant: !use.writes.contains(index)), "b\(index)", .buffer(Int(index)))
            } + [.init(.vector(.uint, 2), "id", .threadPositionInGrid)]
        let call = Metal.Expression.call(
            Self.name(entry.index),
            [Self.state, .convert(.int, [.member(.name("id"), "x")]), .convert(.int, [.member(.name("id"), "y")])]
        )
        return .init(role: .kernel, result: .void, name: entry.name, parameters: parameters, body: making(use) + [.evaluate(call)])
    }

    private func function(_ entry: Shader.Compiler.Entry, _ use: Shader.Compiler.Use) throws(Shader.Compiler.Error) -> Metal.Function {
        guard let signature = module.signature(of: entry.index), use.reads.isEmpty, use.writes.isEmpty else {
            throw .signature(entry: entry.name)
        }
        var parameters: [Metal.Function.Parameter] = []
        for (place, value) in signature.parameters.enumerated() {
            guard let kind = value.metal else { throw .value(value, function: entry.index) }
            parameters.append(.init(kind, "p\(place)"))
        }
        let call = Metal.Expression.call(Self.name(entry.index), [Self.state] + parameters.map { .name($0.name) })
        let results = use.results.sorted()
        if results.isEmpty {
            let kind = signature.results.first.flatMap(\.metal) ?? .void
            let last: Metal.Statement = kind == .void ? .evaluate(call) : .return(call)
            return .init(role: .inline, result: kind, name: entry.name, parameters: parameters, body: making(use) + [last])
        }
        guard signature.results.isEmpty, (2...4).contains(results.count), results == Array(0..<Int32(results.count)) else {
            throw .signature(entry: entry.name)
        }
        let kind = Metal.Kind.vector(.float, results.count)
        let given = Metal.Expression.convert(kind, results.map { .member(Self.state, "result\($0)") })
        return .init(
            role: .inline,
            result: kind,
            name: entry.name,
            parameters: parameters,
            body: making(use) + [.evaluate(call), .return(given)]
        )
    }
}

extension W3C.WebAssembly.Value {
    /// The type that holds such a value, or nil where there is none.
    var metal: Metal.Kind? {
        switch self {
        case .i32: .int
        case .i64: .long
        case .f32: .float
        default: nil
        }
    }
}
