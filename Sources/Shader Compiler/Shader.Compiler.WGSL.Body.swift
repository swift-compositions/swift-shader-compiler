internal import Shader
internal import W3C_WGSL
internal import W3C_WebAssembly

extension Shader.Compiler.WGSL {
    /// A function being written in WGSL, as `Shader.Compiler.Body` writes it in Metal's language: the stack of its
    /// values becomes names and constants, and its blocks become loops left by `break`, with a number that says
    /// which of those around them a branch leaves.
    struct Body {
        typealias Instruction = W3C.WebAssembly.Instruction
        typealias Value = W3C.WebAssembly.Value
        typealias Error = Shader.Compiler.Error

        struct Entry {
            var value: Value
            var expression: Expression
        }

        struct Frame {
            var loop: Bool
            var id: UInt32
            var result: (value: Value, name: String)?
            /// Whether a branch from a block inside names this one.
            var named = false
        }

        let module: W3C.WebAssembly.Module
        let key: Shader.Compiler.Key
        let surveyed: [Int: Shader.Compiler.Use]
        /// The parameters of each function that number a buffer, which the text hands over as the buffer's place.
        let numbering: [Int: [Int: Shader.Compiler.Access]]
        var locals: [Value] = []
        var results: [Value] = []
        var stack: [Entry] = []
        var frames: [Frame] = []
        var made = 0
        var blocks: UInt32 = 0
        var branches = false
        /// The helpers the function calls, and the arrays a place keeps apart, by number, with how many words each has.
        var helpers: Set<Helper> = []
        var arrays: [Int32: Int32] = [:]
        var surface = false
        /// The locals known to hold a constant here.
        var fixed: [Int: Int32] = [:]
        /// Whether the function is an entry, whose parameters a kernel's grid gives.
        var entry = false
        /// Whether `heap` is read and written by atomic operations, as it is where a kernel stores single bytes in
        /// a buffer, so that places beside each other do not lose each other's bytes of a word.
        var atomic = false
        /// Whether the function stores a single byte in a buffer.
        var bytes = false
        /// The names that hold an address in the stack here.
        var stacked: Set<String> = []

        var index: Int { key.index }

        init(
            module: W3C.WebAssembly.Module,
            key: Shader.Compiler.Key,
            numbering: [Int: [Int: Shader.Compiler.Access]],
            surveyed: [Int: Shader.Compiler.Use]
        ) {
            self.module = module
            self.key = key
            self.surveyed = surveyed
            self.numbering = numbering
        }
    }
}

extension Shader.Compiler.WGSL.Body {
    typealias WGSL = Shader.Compiler.WGSL
    typealias Expression = W3C.WGSL.Expression
    typealias Statement = W3C.WGSL.Statement
    typealias Kind = W3C.WGSL.Kind
    typealias Helper = Shader.Compiler.WGSL.Helper

    static let target = Expression.name("shader_target")

    mutating func function() throws(Error) -> W3C.WGSL.Function {
        let place = index - module.imported.count
        guard module.functions.indices.contains(place), let signature = module.signature(of: index), signature.results.count < 2 else {
            throw .malformed(function: index)
        }
        let function = module.functions[place]
        locals = signature.parameters + function.locals
        results = signature.results
        var parameters: [W3C.WGSL.Function.Parameter] = []
        var head: [Statement] = []
        for (number, value) in locals.enumerated() {
            let kind = try kind(value)
            if numbering[index]?[number] != nil {
                parameters.append(.init(.u32, "l\(number)"))
            } else if number < signature.parameters.count {
                // A parameter does not change in WGSL: a local takes its value.
                parameters.append(.init(kind, "p\(number)"))
                head.append(.var(kind, "l\(number)", .name("p\(number)")))
            } else {
                head.append(.var(kind, "l\(number)", Self.zero(value)))
            }
        }
        var body: [Statement] = []
        let ended = try write(function.body, into: &body)
        if !ended, let result = results.first {
            body.append(.return(try pop(result)))
        }
        if ended, let result = results.first, !Self.returns(body.last) { body.append(.return(Self.zero(result))) }
        if branches { head.append(.var(.u32, "shader_target", .u32(0))) }
        return .init(
            result: try results.first.map { value throws(Error) in try kind(value) },
            name: key.name,
            parameters: parameters,
            body: head + body
        )
    }

    private static func returns(_ statement: Statement?) -> Bool {
        if case .return? = statement { true } else { false }
    }

    func kind(_ value: Value) throws(Error) -> Kind {
        switch value {
        case .i32: .i32
        case .i64: WGSL.wide
        case .f32: .f32
        default: throw .value(value, function: index)
        }
    }

    static func zero(_ value: Value) -> Expression {
        switch value {
        case .i64: WGSL.wide(0)
        case .f32: .f32(0)
        default: .i32(0)
        }
    }
}

extension Shader.Compiler.WGSL.Body {
    mutating func pop(_ value: Value? = nil) throws(Error) -> Expression {
        guard let entry = stack.popLast(), value == nil || entry.value == value else { throw .malformed(function: index) }
        return entry.expression
    }

    /// Forgets what locals hold.
    mutating func forget(_ locals: Set<Int>) {
        for local in locals {
            fixed[local] = nil
            stacked.remove("l\(local)")
        }
    }

    /// Whether an expression is an address in the stack.
    func stacked(_ expression: Expression) -> Bool {
        if case .name(let name) = expression { stacked.contains(name) } else { false }
    }

    /// Puts an expression on the stack as it stands: a constant, or a name that does not change.
    mutating func push(_ value: Value, _ expression: Expression) {
        stack.append(.init(value: value, expression: expression))
    }

    /// Works an expression out now, and puts the name of its value on the stack.
    mutating func make(_ value: Value, _ expression: Expression, _ out: inout [Statement]) throws(Error) {
        made += 1
        out.append(.let("t\(made)", expression))
        push(value, .name("t\(made)"))
    }

    /// Keeps the values of locals that stand on the stack by name, before they may change or a block opens.
    mutating func keep(local: Int? = nil, _ out: inout [Statement]) throws(Error) {
        for place in stack.indices {
            guard case .name(let name) = stack[place].expression, name.hasPrefix("l"), local.map({ name == "l\($0)" }) ?? true else { continue }
            made += 1
            out.append(.let("t\(made)", stack[place].expression))
            if stacked(stack[place].expression) { stacked.insert("t\(made)") }
            stack[place].expression = .name("t\(made)")
        }
    }

    /// Writes instructions and says whether what follows them is never reached.
    mutating func write(_ instructions: [Instruction], into out: inout [Statement]) throws(Error) -> Bool {
        for instruction in instructions where try step(instruction, &out) { return true }
        return false
    }

    /// Writes one instruction and says whether what follows it is never reached.
    private mutating func step(_ instruction: Instruction, _ out: inout [Statement]) throws(Error) -> Bool {
        switch instruction {
        case .block(let block, let body): return try open(block, body, &out) { unit, out throws(Error) in try unit.write(body, into: &out) }
        case .loop(let block, let body): return try open(block, body, loop: true, &out) { unit, out throws(Error) in try unit.write(body, into: &out) }
        case .if(let block, let then, let otherwise):
            let condition = WGSL.truth(try pop(.i32))
            return try open(block, then + otherwise, &out) { unit, out throws(Error) in
                try unit.choose(condition, then: then, otherwise: otherwise, &out)
            }
        case .br(let label):
            try branch(label, &out)
            return true
        case .brIf(let label):
            let condition = try pop(.i32)
            var taken: [Statement] = []
            try branch(label, &taken)
            out.append(.if(WGSL.truth(condition), taken))
            return false
        case .brTable(let labels, let otherwise):
            let chosen = try pop(.i32)
            for (number, label) in labels.enumerated() {
                var taken: [Statement] = []
                try branch(label, &taken)
                out.append(.if(.binary(chosen, .equal, .i32(Int32(number))), taken))
            }
            try branch(otherwise, &out)
            return true
        case .return:
            try branch(frames.count, &out)
            return true
        case .unreachable:
            out.append(.return(results.first.map(Self.zero)))
            return true
        default:
            try plain(instruction, &out)
            return false
        }
    }

    private mutating func choose(
        _ condition: Expression,
        then: [Instruction],
        otherwise: [Instruction],
        _ out: inout [Statement]
    ) throws(Error) -> Bool {
        let height = stack.count
        let known = (fixed, stacked)
        var first: [Statement] = []
        let firstEnds = try write(then, into: &first)
        if !firstEnds { try give(&first) }
        stack.removeLast(stack.count - height)
        (fixed, stacked) = known
        var second: [Statement] = []
        let secondEnds = try write(otherwise, into: &second)
        if !secondEnds { try give(&second) }
        stack.removeLast(stack.count - height)
        out.append(.if(condition, first, else: second))
        return true
    }

    /// Hands the innermost block's result over.
    private mutating func give(_ out: inout [Statement]) throws(Error) {
        guard let result = frames.last?.result else { return }
        out.append(.assign(.name(result.name), try pop(result.value)))
    }

    private mutating func open(
        _ block: Instruction.Block,
        _ inside: [Instruction],
        loop: Bool = false,
        _ out: inout [Statement],
        _ body: (inout Self, inout [Statement]) throws(Error) -> Bool
    ) throws(Error) -> Bool {
        try keep(&out)
        let changed = inside.assigned
        if loop { forget(changed) }
        var result: (value: Value, name: String)?
        switch block {
        case .empty: break
        case .result(let value):
            made += 1
            result = (value, "t\(made)")
            out.append(.var(try kind(value), "t\(made)", Self.zero(value)))
        case .type(let type):
            guard module.types.indices.contains(type), module.types[type].parameters.isEmpty, module.types[type].results.isEmpty else {
                throw .block(function: index)
            }
        }
        blocks += 1
        let id = blocks
        frames.append(.init(loop: loop, id: id, result: result))
        let height = stack.count
        var inner: [Statement] = []
        let ended = try body(&self, &inner)
        if !ended { try give(&inner) }
        stack.removeLast(stack.count - height)
        guard let frame = frames.popLast() else { throw .malformed(function: index) }
        // A block is a loop that its end leaves; a loop goes round again from its end.
        if !loop || !ended { inner.append(.break) }
        out.append(.loop(inner))
        if frame.named, !loop {
            out.append(.if(.binary(Self.target, .equal, .u32(id)), [.assign(Self.target, .u32(0))]))
        }
        // A branch to a block further out goes on from here.
        if let around = frames.last, frames.contains(where: \.named) {
            let goes: [Statement] =
                around.loop && around.named
                ? [.if(.binary(Self.target, .equal, .u32(around.id)), [.assign(Self.target, .u32(0)), .continue]), .break]
                : [.break]
            out.append(.if(.binary(Self.target, .unequal, .u32(0)), goes))
        }
        forget(changed)
        if let result { push(result.value, .name(result.name)) }
        return false
    }

    /// Leaves for a label.
    private mutating func branch(_ label: Int, _ out: inout [Statement]) throws(Error) {
        guard label <= frames.count else { throw .malformed(function: index) }
        if label == frames.count {
            guard let result = results.first else {
                out.append(.return(nil))
                return
            }
            guard let entry = stack.last, entry.value == result else { throw .malformed(function: index) }
            out.append(.return(entry.expression))
            return
        }
        let place = frames.count - 1 - label
        if !frames[place].loop, let result = frames[place].result {
            guard let entry = stack.last, entry.value == result.value else { throw .malformed(function: index) }
            out.append(.assign(.name(result.name), entry.expression))
        }
        if label > 0 {
            frames[place].named = true
            branches = true
            out.append(.assign(Self.target, .u32(frames[place].id)))
        }
        out.append(label == 0 && frames[place].loop ? .continue : .break)
    }
}
