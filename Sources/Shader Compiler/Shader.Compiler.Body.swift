internal import Metal_Standard
internal import Shader
internal import W3C_WebAssembly

extension Shader.Compiler {
    /// A function being written: the stack of its values becomes names and constants, and its blocks become blocks
    /// left by `break`, with a number that says which of those around them a branch leaves.
    struct Body {
        typealias Instruction = W3C.WebAssembly.Instruction
        typealias Value = W3C.WebAssembly.Value

        struct Entry {
            var value: Value
            var expression: Metal.Expression
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
        /// The parameters of each function that number a buffer.
        let numbering: [Int: [Int: Shader.Compiler.Access]]
        /// Those of this one, as they are found.
        var numbered: [Int: Shader.Compiler.Access] = [:]
        var locals: [Value] = []
        var results: [Value] = []
        var stack: [Entry] = []
        var frames: [Frame] = []
        var made = 0
        var blocks: UInt32 = 0
        var branches = false
        var use = Use()
        /// The locals known to hold a constant here.
        var fixed: [Int: Int32] = [:]
        /// How many bytes of stack the function takes itself.
        var frame = 0

        /// Whether the function is an entry, whose parameters a kernel's grid or a caller outside gives.
        var entry = false
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

extension Shader.Compiler.Body {
    typealias Error = Shader.Compiler.Error

    static let target = Metal.Expression.name("target")

    mutating func function() throws(Error) -> Metal.Function {
        let place = index - module.imported.count
        guard module.functions.indices.contains(place), let signature = module.signature(of: index), signature.results.count < 2 else {
            throw .malformed(function: index)
        }
        let function = module.functions[place]
        locals = signature.parameters + function.locals
        results = signature.results
        var parameters = [Metal.Function.Parameter(Shader.Compiler.Unit.stateKind, "s")]
        var head: [Metal.Statement] = []
        for (number, value) in locals.enumerated() {
            let kind = try kind(value)
            if let access = numbering[index]?[number] {
                parameters.append(.init(.pointer(.uint, .device, constant: !access.written), "l\(number)"))
            } else if number < signature.parameters.count {
                parameters.append(.init(kind, "l\(number)"))
            } else {
                head.append(.declare(kind, "l\(number)", Self.zero(value)))
            }
        }
        frame = Self.frame(of: function.body)
        var body: [Metal.Statement] = []
        let ended = try write(function.body, into: &body)
        if !ended, let result = results.first {
            body.append(.return(try pop(result)))
        }
        if ended, let result = results.first, !Self.returns(body.last) { body.append(.return(Self.zero(result))) }
        if branches { head.append(.declare(.uint, "target", .uint(0))) }
        return .init(
            role: .inlined,
            result: try results.first.map { value throws(Error) in try kind(value) } ?? .void,
            name: key.name,
            parameters: parameters,
            body: head + body
        )
    }

    private static func returns(_ statement: Metal.Statement?) -> Bool {
        if case .return? = statement { true } else { false }
    }

    /// The bytes a function takes of the stack: the constant its first instructions take from the stack pointer.
    private static func frame(of body: [Instruction]) -> Int {
        for place in body.indices.dropLast(2) {
            if case .globalGet(0) = body[place], case .i32(let size) = body[place + 1], body[place + 2] == .numeric(.i32Sub) { return Int(size) }
        }
        return 0
    }

    func kind(_ value: Value) throws(Error) -> Metal.Kind {
        guard let kind = value.metal else { throw .value(value, function: index) }
        return kind
    }

    static func zero(_ value: Value) -> Metal.Expression {
        switch value {
        case .i64: .convert(.long, [.ulong(0)])
        case .f32: .float(0)
        default: .convert(.int, [.uint(0)])
        }
    }
}

extension Shader.Compiler.Body {
    mutating func pop(_ value: Value? = nil) throws(Error) -> Metal.Expression {
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
    func stacked(_ expression: Metal.Expression) -> Bool {
        if case .name(let name) = expression { stacked.contains(name) } else { false }
    }

    /// Puts an expression on the stack as it stands: a constant, or a name that does not change.
    mutating func push(_ value: Value, _ expression: Metal.Expression) {
        stack.append(.init(value: value, expression: expression))
    }

    /// Works an expression out now, and puts the name of its value on the stack.
    mutating func make(_ value: Value, _ expression: Metal.Expression, _ out: inout [Metal.Statement]) throws(Error) {
        made += 1
        out.append(.declare(try kind(value), "t\(made)", expression))
        push(value, .name("t\(made)"))
    }

    /// Keeps the values of locals that stand on the stack by name, before they may change or a block opens.
    mutating func keep(local: Int? = nil, _ out: inout [Metal.Statement]) throws(Error) {
        for place in stack.indices {
            guard case .name(let name) = stack[place].expression, name.hasPrefix("l"), local.map({ name == "l\($0)" }) ?? true else { continue }
            made += 1
            out.append(.declare(try kind(stack[place].value), "t\(made)", stack[place].expression))
            if stacked(stack[place].expression) { stacked.insert("t\(made)") }
            stack[place].expression = .name("t\(made)")
        }
    }

    /// Writes instructions and says whether what follows them is never reached.
    mutating func write(_ instructions: [Instruction], into out: inout [Metal.Statement]) throws(Error) -> Bool {
        for instruction in instructions where try step(instruction, &out) { return true }
        return false
    }

    /// Writes one instruction and says whether what follows it is never reached.
    private mutating func step(_ instruction: Instruction, _ out: inout [Metal.Statement]) throws(Error) -> Bool {
        switch instruction {
        case .block(let block, let body): return try open(block, body, &out) { unit, out throws(Error) in try unit.write(body, into: &out) }
        case .loop(let block, let body): return try open(block, body, loop: true, &out) { unit, out throws(Error) in try unit.write(body, into: &out) }
        case .if(let block, let then, let otherwise):
            let condition = Metal.Expression.binary(try pop(.i32), .unequal, .uint(0))
            return try open(block, then + otherwise, &out) { unit, out throws(Error) in
                try unit.choose(condition, then: then, otherwise: otherwise, &out)
            }
        case .br(let label):
            try branch(label, &out)
            return true
        case .brIf(let label):
            let condition = try pop(.i32)
            var taken: [Metal.Statement] = []
            try branch(label, &taken)
            out.append(.if(.binary(condition, .unequal, .uint(0)), taken))
            return false
        case .brTable(let labels, let otherwise):
            let chosen = try pop(.i32)
            for (number, label) in labels.enumerated() {
                var taken: [Metal.Statement] = []
                try branch(label, &taken)
                out.append(.if(.binary(chosen, .equal, .uint(UInt32(number))), taken))
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
        _ condition: Metal.Expression,
        then: [Instruction],
        otherwise: [Instruction],
        _ out: inout [Metal.Statement]
    ) throws(Error) -> Bool {
        let height = stack.count
        let known = (fixed, stacked)
        var first: [Metal.Statement] = []
        let firstEnds = try write(then, into: &first)
        if !firstEnds { try give(&first) }
        stack.removeLast(stack.count - height)
        (fixed, stacked) = known
        var second: [Metal.Statement] = []
        let secondEnds = try write(otherwise, into: &second)
        if !secondEnds { try give(&second) }
        stack.removeLast(stack.count - height)
        out.append(.if(condition, first, else: second))
        return true
    }

    /// Hands the innermost block's result over.
    private mutating func give(_ out: inout [Metal.Statement]) throws(Error) {
        guard let result = frames.last?.result else { return }
        out.append(.assign(.name(result.name), try pop(result.value)))
    }

    private mutating func open(
        _ block: Instruction.Block,
        _ inside: [Instruction],
        loop: Bool = false,
        _ out: inout [Metal.Statement],
        _ body: (inout Self, inout [Metal.Statement]) throws(Error) -> Bool
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
            out.append(.declare(try kind(value), "t\(made)", Self.zero(value)))
        case .type(let type):
            guard module.types.indices.contains(type), module.types[type].parameters.isEmpty, module.types[type].results.isEmpty else {
                throw .block(function: index)
            }
        }
        blocks += 1
        let id = blocks
        frames.append(.init(loop: loop, id: id, result: result))
        let height = stack.count
        var inner: [Metal.Statement] = []
        let ended = try body(&self, &inner)
        if !ended { try give(&inner) }
        stack.removeLast(stack.count - height)
        guard let frame = frames.popLast() else { throw .malformed(function: index) }
        if loop {
            if !ended { inner.append(.break) }
            out.append(.while(.bool(true), inner))
        } else {
            out.append(.once(inner))
        }
        if frame.named, !loop {
            out.append(.if(.binary(Self.target, .equal, .uint(id)), [.assign(Self.target, .uint(0))]))
        }
        // A branch to a block further out goes on from here.
        if let around = frames.last, frames.contains(where: \.named) {
            let goes: [Metal.Statement] =
                around.loop && around.named
                ? [.if(.binary(Self.target, .equal, .uint(around.id)), [.assign(Self.target, .uint(0)), .continue]), .break]
                : [.break]
            out.append(.if(.binary(Self.target, .unequal, .uint(0)), goes))
        }
        forget(changed)
        if let result { push(result.value, .name(result.name)) }
        return false
    }

    /// Leaves for a label.
    private mutating func branch(_ label: Int, _ out: inout [Metal.Statement]) throws(Error) {
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
            out.append(.assign(Self.target, .uint(frames[place].id)))
        }
        out.append(label == 0 && frames[place].loop ? .continue : .break)
    }
}
