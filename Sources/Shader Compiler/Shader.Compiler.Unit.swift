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
        var written: [Metal.Function] = []
        /// What each function uses as first written, with all it reaches.
        var surveyed: [Int: Use] = [:]
        var uses: [Key: Use] = [:]
        /// The parameters of each function that number a buffer, which the text hands over as pointers.
        var numbering: [Int: [Int: Access]] = [:]
        /// How many bytes of stack a function and those it calls take.
        var depths: [Key: Int] = [:]
        var reaching: Set<Int> = []
        /// The functions in the order they were written, each after those it calls.
        var order: [Shader.Compiler.Key] = []
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

    /// The value the stack starts from.
    var top: Int32 {
        guard case .i32(let value)? = module.globals.first?.initial.first else { return 0 }
        return value
    }

    /// Finds what a function and all it reaches use, and which parameters number buffers.
    private mutating func survey(_ index: Int) throws(Shader.Compiler.Error) {
        guard surveyed[index] == nil else { return }
        guard reaching.insert(index).inserted else { throw .recursion(function: index) }
        let imported = module.imported.count
        guard module.functions.indices.contains(index - imported) else { throw .malformed(function: index) }
        let callees = module.functions[index - imported].body.callees.subtracting(0..<imported)
        for callee in callees.sorted() { try survey(callee) }
        var body = Shader.Compiler.Body(module: module, key: .init(index: index), numbering: numbering, surveyed: surveyed)
        body.entry = entries.contains { $0.index == index }
        _ = try body.function()
        numbering[index] = body.numbered
        var use = body.use
        for callee in callees { if let its = surveyed[callee] { use.formUnion(its) } }
        surveyed[index] = use
        reaching.remove(index)
    }

    /// Writes a function and all it reaches, callees first.
    private mutating func reach(_ key: Shader.Compiler.Key) throws(Shader.Compiler.Error) {
        guard uses[key] == nil else { return }
        var body = Shader.Compiler.Body(module: module, key: key, numbering: numbering, surveyed: surveyed)
        body.entry = entries.contains { $0.index == key.index }
        let function = try body.function()
        var use = body.use
        var below = 0
        for callee in body.use.calls.sorted() {
            try reach(callee)
            if let its = uses[callee] { use.formUnion(its) }
            below = max(below, depths[callee] ?? 0)
        }
        uses[key] = use
        depths[key] = below + body.frame
        written.append(function)
        order.append(key)
    }

    /// An entry's function, with the buffers it only reads at places known beforehand.
    func key(_ entry: Shader.Compiler.Entry) -> Shader.Compiler.Key {
        guard entry.kind == .kernel, let use = surveyed[entry.index] else { return .init(index: entry.index) }
        return .init(index: entry.index, constants: use.fixed.subtracting(use.reads).subtracting(use.writes))
    }

    /// How many bytes of stack an entry takes.
    func size(_ entry: Shader.Compiler.Entry) -> Int { ((depths[key(entry)] ?? 0) + 15) & ~15 }

    /// Finds what every entry reaches and uses, and writes each function once.
    mutating func analyse() throws(Shader.Compiler.Error) {
        for entry in entries { try survey(entry.index) }
        for entry in entries { try reach(key(entry)) }
    }

    /// The whole text.
    mutating func source() throws(Shader.Compiler.Error) -> Metal.Source {
        try analyse()
        var all = Shader.Compiler.Use()
        for use in uses.values { all.formUnion(use) }
        let memory = Shader.Compiler.Memory(top: top, size: entries.map(size).max() ?? 0, image: image)
        var items: [Metal.Source.Item] = [.structure(state(all, memory: memory))]
        if !image.words.isEmpty, !all.helpers.isDisjoint(with: Shader.Compiler.Helper.loading) { items.append(image.item) }
        items += Shader.Compiler.Helper.needed(by: all.helpers).map { .function($0.function(memory)) }
        items += written.map { .function($0) }
        for entry in entries {
            let use = uses[key(entry)] ?? .init()
            switch entry.kind {
            case .kernel: items.append(.function(kernel(entry, use, memory)))
            case .function: items.append(.function(try function(entry, use, memory)))
            case .vertex: items += try vertex(entry, use, memory)
            case .fragment: items += try fragment(entry, use, memory)
            }
        }
        return Metal.Source(items)
    }

    private func state(_ use: Shader.Compiler.Use, memory: Shader.Compiler.Memory) -> Metal.Structure {
        var members: [Metal.Structure.Member] = []
        if memory.size > 0 { members.append(.init(.pointer(.uint, .thread), "memory")) }
        members += module.globals.enumerated().map { place, global in
            .init(global.kind.value.metal ?? .uint, "g\(place)")
        }
        members += use.constants.sorted().map { .init(.pointer(.uint, .constant), "c\($0)") }
        members += use.reads.sorted().map { .init(.pointer(.uint, .device, constant: true), "r\($0)") }
        members += use.writes.sorted().map { .init(.pointer(.uint, .device), "w\($0)") }
        if use.lanes { members += [.init(.uint, "lane"), .init(.uint, "lanes")] }
        members += use.locals.keys.sorted().map { .init(.pointer(.uint, .thread), "local\($0)") }
        if use.surface { members.append(.init(.texture(.float), "surface")) }
        members += use.textures.sorted().map { .init(.texture(.float, written: false), "t\($0)") }
        members += use.stores.sorted().map { .init(.texture(.float), "u\($0)") }
        if use.samples { members.append(.init(.sampler, "between")) }
        if use.texel { members.append(.init(.vector(.float, 4), "texel")) }
        if use.position { members.append(.init(.vector(.float, 4), "position")) }
        members += use.handed.merging(use.taken) { first, _ in first }.sorted { $0.key < $1.key }.map { .init(.vector($0.value ? .uint : .float, 4), Self.member($0.key, $0.value).name) }
        members += use.results.sorted().map { .init(.float, "result\($0)") }
        return .init(name: "Shader_State", members: members)
    }

    /// The statements that make a state, with the buffers a kernel is handed.
    private func making(_ entry: Shader.Compiler.Entry, _ use: Shader.Compiler.Use, _ memory: Shader.Compiler.Memory) -> [Metal.Statement] {
        var statements: [Metal.Statement] = [.declare(.structure("Shader_State"), "s", nil)]
        let size = size(entry)
        if size > 0 {
            statements.insert(.array(.uint, "memory", size / 4), at: 0)
            statements.append(.assign(.member(Self.state, "memory"), .name("memory")))
        }
        for (place, global) in module.globals.enumerated() {
            let value: Metal.Expression
            if place == 0, memory.size > 0 {
                // The stack begins where the entry's own words end.
                statements.append(.assign(.member(Self.state, "g0"), .convert(.int, [.uint(UInt32(bitPattern: memory.bottom) + UInt32(size))])))
                continue
            }
            switch global.initial.first {
            case .i32(let number): value = .convert(.int, [.uint(UInt32(bitPattern: number))])
            case .i64(let number): value = .convert(.long, [.ulong(UInt64(bitPattern: number))])
            case .f32(let bits): value = .float(bits)
            default: continue
            }
            statements.append(.assign(.member(Self.state, "g\(place)"), value))
        }
        statements += use.constants.sorted().map { .assign(.member(Self.state, "c\($0)"), .name("b\($0)")) }
        statements += use.reads.sorted().map { .assign(.member(Self.state, "r\($0)"), .name("b\($0)")) }
        statements += use.writes.sorted().map { .assign(.member(Self.state, "w\($0)"), .name("b\($0)")) }
        for (number, count) in use.locals.sorted(by: { $0.key < $1.key }) {
            statements.insert(.array(.uint, "local\(number)", Int(count)), at: 0)
            statements.append(.assign(.member(Self.state, "local\(number)"), .name("local\(number)")))
        }
        if use.lanes { statements += ["lane", "lanes"].map { .assign(.member(Self.state, $0), .name($0)) } }
        if use.surface { statements.append(.assign(.member(Self.state, "surface"), .name("surface"))) }
        statements += use.textures.sorted().map { .assign(.member(Self.state, "t\($0)"), .name("t\($0)")) }
        statements += use.stores.sorted().map { .assign(.member(Self.state, "u\($0)"), .name("u\($0)")) }
        if use.samples { statements.append(.assign(.member(Self.state, "between"), .name("between"))) }
        return statements
    }

    /// A vector one stage hands the next at a place: of `float`, or of `uint` where it is not interpolated.
    private static func member(_ place: Int32, _ flat: Bool) -> Metal.Structure.Member {
        .init(.vector(flat ? .uint : .float, 4), flat ? "f\(place)" : "v\(place)", at: .place(Int(place), flat: flat))
    }

    /// The buffers, textures and sampler an entry is handed. Texture 0 is the surface a kernel writes, so the
    /// texture bound at a number is one further.
    private func bound(_ use: Shader.Compiler.Use) -> [Metal.Function.Parameter] {
        var parameters: [Metal.Function.Parameter] = use.reads.union(use.writes).union(use.constants).sorted().map { index in
            let kind: Metal.Kind =
                use.constants.contains(index) ? .pointer(.uint, .constant) : .pointer(.uint, .device, constant: !use.writes.contains(index))
            return .init(kind, "b\(index)", .buffer(Int(index)))
        }
        parameters += use.textures.sorted().map { .init(.texture(.float, written: false), "t\($0)", .texture(Int($0) + 1)) }
        parameters += use.stores.sorted().map { .init(.texture(.float), "u\($0)", .texture(Int($0) + 1)) }
        if use.samples { parameters.append(.init(.sampler, "between", .sampler(0))) }
        return parameters
    }

    /// A vertex stage: the structure it gives, and its function.
    private func vertex(_ entry: Shader.Compiler.Entry, _ use: Shader.Compiler.Use, _ memory: Shader.Compiler.Memory) throws(Shader.Compiler.Error) -> [Metal.Source.Item] {
        guard use.position, use.writes.isEmpty, use.stores.isEmpty, !use.surface, !use.lanes else { throw .stage(entry: entry.exported) }
        let name = "Shader_Handed_\(entry.name)"
        let places = use.handed.sorted { $0.key < $1.key }.map(Self.member)
        let structure = Metal.Structure(name: name, members: [.init(.vector(.float, 4), "position", at: .position)] + places)
        let parameters = [Metal.Function.Parameter(.uint, "corner", .vertexID), .init(.uint, "instance", .instanceID)] + bound(use)
        let call = Metal.Expression.call(key(entry).name, [Self.state, .convert(.int, [.name("corner")]), .convert(.int, [.name("instance")])])
        var body = making(entry, use, memory) + [.evaluate(call), .declare(.structure(name), "handed", nil)]
        body += (["position"] + places.map(\.name)).map { .assign(.member(.name("handed"), $0), .member(Self.state, $0)) }
        body.append(.return(.name("handed")))
        return [.structure(structure), .function(.init(role: .vertex, result: .structure(name), name: "vertex_\(entry.name)", parameters: parameters, body: body))]
    }

    /// A fragment stage: the structure it takes, and its function.
    private func fragment(_ entry: Shader.Compiler.Entry, _ use: Shader.Compiler.Use, _ memory: Shader.Compiler.Memory) throws(Shader.Compiler.Error) -> [Metal.Source.Item] {
        guard use.results == [0, 1, 2, 3], use.writes.isEmpty, use.stores.isEmpty, !use.surface, !use.lanes else { throw .stage(entry: entry.exported) }
        let name = "Shader_Taken_\(entry.name)"
        let places = use.taken.sorted { $0.key < $1.key }.map(Self.member)
        let structure = Metal.Structure(name: name, members: [.init(.vector(.float, 4), "position", at: .position)] + places)
        let parameters = [Metal.Function.Parameter(.structure(name), "taken", .stageIn)] + bound(use)
        let at = Metal.Expression.member(.name("taken"), "position")
        let call = Metal.Expression.call(key(entry).name, [Self.state, .member(at, "x"), .member(at, "y")])
        var body = making(entry, use, memory)
        body += places.map { .assign(.member(Self.state, $0.name), .member(.name("taken"), $0.name)) }
        body += [.evaluate(call), .return(.convert(.vector(.float, 4), (0..<4).map { .member(Self.state, "result\($0)") }))]
        return [.structure(structure), .function(.init(role: .fragment, result: .vector(.float, 4), name: "fragment_\(entry.name)", parameters: parameters, body: body))]
    }

    private func kernel(_ entry: Shader.Compiler.Entry, _ use: Shader.Compiler.Use, _ memory: Shader.Compiler.Memory) -> Metal.Function {
        var parameters = bound(use) + [.init(.vector(.uint, 2), "id", .threadPositionInGrid)]
        if use.surface { parameters.append(.init(.texture(.float), "surface", .texture(0))) }
        if use.lanes {
            parameters += [.init(.uint, "lane", .threadIndexInSimdgroup), .init(.uint, "lanes", .threadsPerSimdgroup)]
        }
        let call = Metal.Expression.call(
            key(entry).name,
            [Self.state, .convert(.int, [.member(.name("id"), "x")]), .convert(.int, [.member(.name("id"), "y")])]
        )
        return .init(role: .kernel, result: .void, name: entry.name, parameters: parameters, body: making(entry, use, memory) + [.evaluate(call)])
    }

    private func function(_ entry: Shader.Compiler.Entry, _ use: Shader.Compiler.Use, _ memory: Shader.Compiler.Memory) throws(Shader.Compiler.Error) -> Metal.Function {
        guard let signature = module.signature(of: entry.index), use.reads.isEmpty, use.writes.isEmpty, !use.lanes, !use.surface,
            use.textures.isEmpty, use.stores.isEmpty, !use.position, use.handed.isEmpty, use.taken.isEmpty
        else {
            throw .signature(entry: entry.name)
        }
        var parameters: [Metal.Function.Parameter] = []
        for (place, value) in signature.parameters.enumerated() {
            guard let kind = value.metal else { throw .value(value, function: entry.index) }
            parameters.append(.init(kind, "p\(place)"))
        }
        let call = Metal.Expression.call(key(entry).name, [Self.state] + parameters.map { .name($0.name) })
        let results = use.results.sorted()
        if results.isEmpty {
            let kind = signature.results.first.flatMap(\.metal) ?? .void
            let last: Metal.Statement = kind == .void ? .evaluate(call) : .return(call)
            return .init(role: .inline, result: kind, name: entry.name, parameters: parameters, body: making(entry, use, memory) + [last])
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
            body: making(entry, use, memory) + [.evaluate(call), .return(given)]
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
