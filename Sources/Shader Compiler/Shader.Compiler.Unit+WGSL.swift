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
            guard entry.kind == .kernel else { throw .signature(entry: entry.name) }
            texts[entry.name] = try wgsl(entry)
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
            .variable(.storage(written: true), .array(bytes ? .atomic(.u32) : .u32, nil), WGSL.heap, binding: .init(group: 0, binding: 0)),
            .variable(.uniform, .structure("Shader_Dispatch"), WGSL.dispatch, binding: .init(group: 0, binding: 1)),
        ]
        if !image.words.isEmpty, needed.contains(where: WGSL.Helper.loading.contains) {
            items.append(.variable(.storage(written: false), .array(.u32, nil), WGSL.image, binding: .init(group: 0, binding: 2)))
        }
        if surface { items.append(.variable(nil, .storageTexture("rgba8unorm"), WGSL.surface, binding: .init(group: 0, binding: 3))) }
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
        items.append(.function(kernel(entry, root, memory, lanes: uses[root]?.lanes ?? false)))
        return W3C.WGSL.Source(items)
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
        body.append(.call(root.name, [.construct(.i32, [.member(id, "x")]), .construct(.i32, [.member(id, "y")])]))
        return .init(compute: [64, 1, 1], name: entry.name, parameters: [.init(.vector(.u32, 3), "id", .globalInvocationID)], body: body)
    }
}
