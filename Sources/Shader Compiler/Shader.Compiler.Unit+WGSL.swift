internal import Shader
internal import W3C_WGSL
internal import W3C_WebAssembly

extension Shader.Compiler.Unit {
    typealias WGSL = Shader.Compiler.WGSL

    /// Each kernel's text in WGSL, by its name.
    mutating func wgsl() throws(Shader.Compiler.Error) -> [String: W3C.WGSL.Source] {
        try analyse()
        var texts: [String: W3C.WGSL.Source] = [:]
        for entry in entries {
            guard entry.kind != .function else { throw .signature(entry: entry.name) }
            texts[entry.draws ? entry.exported : entry.name] = try wgsl(entry)
        }
        return texts
    }

    /// The functions a key reaches, itself with them.
    private func reached(from root: Shader.Compiler.Key) -> Set<Shader.Compiler.Key> {
        var reached: Set<Shader.Compiler.Key> = []
        var waiting = [root]
        while let key = waiting.popLast() {
            guard reached.insert(key).inserted else { continue }
            waiting += uses[key]?.calls ?? []
        }
        return reached
    }

    private func wgsl(_ entry: Shader.Compiler.Entry) throws(Shader.Compiler.Error) -> W3C.WGSL.Source {
        let root = key(entry)
        let reached = reached(from: root)
        // A kernel's stack ends where the module's begins, and is as deep as the kernel's calls go.
        let memory = Shader.Compiler.Memory(top: top, size: size(entry), image: image)
        var functions: [W3C.WGSL.Function] = []
        var helpers: Set<WGSL.Helper> = []
        var arrays: [Int32: Int32] = [:]
        var surface = false
        var bytes = false
        // A kernel that stores single bytes in a buffer is written again with `heap` atomic.
        for atomic in [false, true] {
            functions = []
            helpers = []
            arrays = [:]
            surface = false
            bytes = false
            for key in order where reached.contains(key) {
                var body = WGSL.Body(module: module, key: key, numbering: numbering, surveyed: surveyed)
                body.entry = key.index == entry.index
                body.atomic = atomic
                body.stage = entry.draws ? entry.exported : nil
                functions.append(try body.function())
                helpers.formUnion(body.helpers)
                arrays.merge(body.arrays, uniquingKeysWith: max)
                surface = surface || body.surface
                bytes = bytes || body.bytes
            }
            if !bytes || atomic { break }
        }
        let needed = WGSL.Helper.needed(by: helpers)
        var items: [W3C.WGSL.Source.Item] = [
            .structure(.init(name: "Shader_Dispatch", members: [.init(.vector(.u32, 4), "grid"), .init(.array(.vector(.u32, 4), WGSL.buffers / 4), "bases")])),
            .variable(.storage(written: !entry.draws), .array(bytes ? .atomic(.u32) : .u32, nil), WGSL.heap, binding: .init(group: 0, binding: 0)),
            .variable(.uniform, .structure("Shader_Dispatch"), WGSL.dispatch, binding: .init(group: 0, binding: 1)),
        ]
        if !image.words.isEmpty, needed.contains(where: WGSL.Helper.loading.contains) {
            items.append(.variable(.storage(written: false), .array(.u32, nil), WGSL.image, binding: .init(group: 0, binding: 2)))
        }
        if surface { items.append(.variable(nil, .storageTexture("rgba8unorm"), WGSL.surface, binding: .init(group: 0, binding: 3))) }
        let use = uses[root] ?? .init()
        guard use.textures.isDisjoint(with: use.stores) else { throw .constant(function: entry.index) }
        if use.samples { items.append(.variable(nil, .sampler, WGSL.sampler, binding: .init(group: 0, binding: 4))) }
        for number in use.textures.union(use.stores).sorted() {
            let kind: W3C.WGSL.Kind = use.stores.contains(number) ? .storageTexture("rgba16float") : .texture
            items.append(.variable(nil, kind, WGSL.texture(number), binding: .init(group: 1, binding: Int(number))))
        }
        if use.texel { items.append(.variable(.private, .vector(.f32, 4), WGSL.texel)) }
        if use.position { items.append(.variable(.private, .vector(.f32, 4), WGSL.position)) }
        if !use.results.isEmpty { items.append(.variable(.private, .vector(.f32, 4), WGSL.color)) }
        for (place, flat) in use.handed.merging(use.taken, uniquingKeysWith: { first, _ in first }).sorted(by: { $0.key < $1.key }) {
            items.append(.variable(.private, .vector(flat ? .u32 : .f32, 4), WGSL.handed(place, flat: flat)))
        }
        if memory.size > 0 { items.append(.variable(.private, .array(.u32, memory.size / 4), "shader_memory")) }
        for (place, global) in module.globals.enumerated() {
            let value = global.kind.value
            guard value == .i32 || value == .i64 || value == .f32 else { continue }
            items.append(.variable(.private, value == .i32 ? .i32 : value == .i64 ? WGSL.wide : .f32, "shader_g\(place)"))
        }
        for (number, count) in arrays.sorted(by: { $0.key < $1.key }) {
            items.append(.variable(.private, .array(.u32, Int(count)), "shader_local\(number)"))
        }
        items += needed.map { .function($0.function(memory)) }
        items += functions.map { .function($0) }
        switch entry.kind {
        case .vertex: items += try vertex(entry, root, use, memory)
        case .fragment: items.append(.function(try fragment(entry, root, use, memory)))
        default: items.append(.function(kernel(entry, root, memory, lanes: use.lanes)))
        }
        return W3C.WGSL.Source(items)
    }

    /// The globals' first values.
    private func starting(_ memory: Shader.Compiler.Memory) -> [W3C.WGSL.Statement] {
        var body: [W3C.WGSL.Statement] = []
        for (place, global) in module.globals.enumerated() {
            let value: W3C.WGSL.Expression
            if place == 0, memory.size > 0 {
                // The stack begins where the entry's own words end.
                value = .i32(Int32(bitPattern: UInt32(bitPattern: memory.bottom) &+ UInt32(memory.size)))
            } else {
                switch global.initial.first {
                case .i32(let number): value = .i32(number)
                case .i64(let number): value = WGSL.wide(UInt64(bitPattern: number))
                case .f32(let bits): value = .f32(bits)
                default: continue
                }
            }
            body.append(.assign(.name("shader_g\(place)"), value))
        }
        return body
    }

    /// A vertex stage's entry point, and the structure it gives: the position, and what it hands on at each place.
    private func vertex(
        _ entry: Shader.Compiler.Entry,
        _ root: Shader.Compiler.Key,
        _ use: Shader.Compiler.Use,
        _ memory: Shader.Compiler.Memory
    ) throws(Shader.Compiler.Error) -> [W3C.WGSL.Source.Item] {
        guard use.position, !use.lanes else { throw .stage(entry: entry.exported) }
        let places = use.handed.sorted { $0.key < $1.key }
        var members = [W3C.WGSL.Structure.Member(.vector(.f32, 4), "position", at: .builtin(.position))]
        members += places.map { .init(.vector($0.value ? .u32 : .f32, 4), $0.value ? "f\($0.key)" : "v\($0.key)", at: .location(Int($0.key), flat: $0.value)) }
        let given = [W3C.WGSL.Expression.name(WGSL.position)] + places.map { .name(WGSL.handed($0.key, flat: $0.value)) }
        let body =
            starting(memory) + [
                .call(root.name, [.construct(.i32, [.name("corner")]), .construct(.i32, [.name("instance")])]),
                .return(.construct(.structure("Shader_Handed"), given)),
            ]
        let function = W3C.WGSL.Function(
            stage: .vertex,
            result: .structure("Shader_Handed"),
            name: entry.exported,
            parameters: [.init(.u32, "corner", .vertexIndex), .init(.u32, "instance", .instanceIndex)],
            body: body
        )
        return [.structure(.init(name: "Shader_Handed", members: members)), .function(function)]
    }

    /// A fragment stage's entry point: the pixel's middle, what was handed on at each place, and the colour given.
    private func fragment(
        _ entry: Shader.Compiler.Entry,
        _ root: Shader.Compiler.Key,
        _ use: Shader.Compiler.Use,
        _ memory: Shader.Compiler.Memory
    ) throws(Shader.Compiler.Error) -> W3C.WGSL.Function {
        guard use.results == [0, 1, 2, 3], !use.lanes else { throw .stage(entry: entry.exported) }
        let places = use.taken.sorted { $0.key < $1.key }
        var parameters = [W3C.WGSL.Function.Parameter(.vector(.f32, 4), "at", .position)]
        parameters += places.map { .init(.vector($0.value ? .u32 : .f32, 4), $0.value ? "f\($0.key)" : "v\($0.key)", at: .location(Int($0.key), flat: $0.value)) }
        var body = starting(memory)
        body += places.map { .assign(.name(WGSL.handed($0.key, flat: $0.value)), .name($0.value ? "f\($0.key)" : "v\($0.key)")) }
        body += [.call(root.name, [.member(.name("at"), "x"), .member(.name("at"), "y")]), .return(.name(WGSL.color))]
        return .init(stage: .fragment, result: .vector(.f32, 4), given: .location(0), name: entry.exported, parameters: parameters, body: body)
    }

    /// The entry point: the grid's place, the globals' first values, and the call.
    private func kernel(_ entry: Shader.Compiler.Entry, _ root: Shader.Compiler.Key, _ memory: Shader.Compiler.Memory, lanes: Bool) -> W3C.WGSL.Function {
        let id = W3C.WGSL.Expression.name("id")
        let grid = W3C.WGSL.Expression.member(.name(WGSL.dispatch), "grid")
        let outside = W3C.WGSL.Expression.binary(
            .binary(.member(id, "x"), .atLeast, .member(grid, "x")),
            .either,
            .binary(.member(id, "y"), .atLeast, .member(grid, "y"))
        )
        var body: [W3C.WGSL.Statement] = [.if(outside, [.return(nil)])]
        // A kernel's lanes are one, so a kernel that tells its lanes apart does a row's work in its first place alone.
        if lanes { body.append(.if(.binary(.member(id, "x"), .unequal, .u32(0)), [.return(nil)])) }
        body += starting(memory)
        body.append(.call(root.name, [.construct(.i32, [.member(id, "x")]), .construct(.i32, [.member(id, "y")])]))
        return .init(compute: [64, 1, 1], name: entry.name, parameters: [.init(.vector(.u32, 3), "id", .globalInvocationID)], body: body)
    }
}
