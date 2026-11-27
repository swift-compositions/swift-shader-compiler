internal import Shader
internal import W3C_WGSL
internal import W3C_WebAssembly

extension Shader.Compiler.WGSL.Body {
    /// Writes an instruction that neither opens a block nor leaves one.
    mutating func plain(_ instruction: Instruction, _ out: inout [Statement]) throws(Error) {
        switch instruction {
        case .nop: break
        case .drop: _ = try pop()
        case .select, .selectOf:
            let condition = try pop(.i32)
            let second = try pop()
            guard let value = stack.last?.value else { throw .malformed(function: index) }
            let first = try pop()
            let address = stacked(first) && stacked(second)
            defer { if address { stacked.insert("t\(made)") } }
            try make(value, .call("select", [second, first, WGSL.truth(condition)]), &out)
        case .localGet(let number):
            guard locals.indices.contains(number) else { throw .malformed(function: index) }
            if let fixed = fixed[number] {
                push(.i32, .i32(fixed))
            } else {
                push(locals[number], .name("l\(number)"))
            }
        case .localSet(let number): try set(number, try pop(), &out)
        case .localTee(let number):
            guard let entry = stack.last else { throw .malformed(function: index) }
            _ = try pop()
            try set(number, entry.expression, &out)
            if let whole = fixed[number] {
                push(.i32, .i32(whole))
            } else {
                push(entry.value, .name("l\(number)"))
            }
        case .globalGet(let number):
            guard module.globals.indices.contains(number) else { throw .malformed(function: index) }
            try make(module.globals[number].kind.value, .name("shader_g\(number)"), &out)
            if number == 0 { stacked.insert("t\(made)") }
        case .globalSet(let number): out.append(.assign(.name("shader_g\(number)"), try pop()))
        case .i32(let number): push(.i32, .i32(number))
        case .i64(let number): push(.i64, WGSL.wide(UInt64(bitPattern: number)))
        case .f32(let bits): push(.f32, WGSL.float(bits, &helpers))
        case .f64: throw .value(.f64, function: index)
        case .load(let load, let address): try self.load(load, address, &out)
        case .store(let store, let address): try self.store(store, address, &out)
        case .memoryCopy: try fill(&out, copying: true)
        case .memoryFill: try fill(&out, copying: false)
        case .numeric(let numeric): try self.numeric(numeric, &out)
        case .saturating(let saturating):
            let value = try pop(.f32)
            switch saturating {
            case .i32TruncSatF32S: try make(.i32, .construct(.i32, [value]), &out)
            case .i32TruncSatF32U: try make(.i32, WGSL.signed(.construct(.u32, [value])), &out)
            case .i64TruncSatF32S: try make(.i64, call(.truncate, [value]), &out)
            case .i64TruncSatF32U: try make(.i64, call(.truncateUnsigned, [value]), &out)
            default: throw .value(.f64, function: index)
            }
        case .call(let callee): try call(callee, &out)
        default: throw .instruction("\(instruction)", function: index)
        }
    }

    /// A call of a helper, which the text then holds.
    mutating func call(_ helper: Helper, _ arguments: [Expression]) -> Expression {
        helpers.insert(helper)
        return .call(helper.rawValue, arguments)
    }

    private mutating func set(_ number: Int, _ value: Expression, _ out: inout [Statement]) throws(Error) {
        guard locals.indices.contains(number) else { throw .malformed(function: index) }
        fixed[number] = locals[number] == .i32 ? Self.number(value) : nil
        let address = stacked(value)
        try keep(local: number, &out)
        if address { stacked.insert("l\(number)") } else { stacked.remove("l\(number)") }
        if value != .name("l\(number)") { out.append(.assign(.name("l\(number)"), value)) }
    }

    private mutating func arguments(_ count: Int) throws(Error) -> [Expression] {
        guard stack.count >= count else { throw .malformed(function: index) }
        defer { stack.removeLast(count) }
        return stack.suffix(count).map(\.expression)
    }

    private mutating func call(_ callee: Int, _ out: inout [Statement]) throws(Error) {
        let imported = module.imported
        guard let signature = module.signature(of: callee) else { throw .malformed(function: index) }
        let arguments = try arguments(signature.parameters.count)
        guard !imported.indices.contains(callee) else {
            try outside(imported[callee].module, imported[callee].name, arguments, &out)
            return
        }
        let its = surveyed[callee]?.fixed ?? []
        let called = Shader.Compiler.Key(index: callee, constants: key.constants.intersection(its))
        var given: [Expression] = []
        for (place, argument) in arguments.enumerated() {
            given.append(numbering[callee]?[place] != nil ? try buffer(argument) : argument)
        }
        if let result = signature.results.first {
            try make(result, .call(called.name, given), &out)
        } else {
            out.append(.call(called.name, given))
        }
    }

    /// The number a constant is.
    static func number(_ expression: Expression?) -> Int32? {
        guard case .i32(let number)? = expression else { return nil }
        return number
    }

    private func constant(_ expression: Expression?) throws(Error) -> Int32 {
        guard let number = Self.number(expression) else { throw .constant(function: index) }
        return number
    }

    /// The place in `heap` of the buffer a number stands for: by a constant number, or as a parameter hands it over.
    private func buffer(_ expression: Expression?) throws(Error) -> Expression {
        if let number = Self.number(expression) {
            guard (0..<Int32(WGSL.buffers)).contains(number) else { throw .constant(function: index) }
            return WGSL.base(number)
        }
        guard !entry, case .name(let name)? = expression, name.hasPrefix("l"), let local = Int(name.dropFirst()),
            numbering[index]?[local] != nil
        else { throw .constant(function: index) }
        return .name(name)
    }

    /// The word of a buffer at a byte offset.
    private mutating func word(_ memory: Expression, _ offset: Expression, plus: UInt32 = 0, _ out: inout [Statement]) -> Expression {
        let at: Expression
        if let number = Self.number(offset) {
            at = .binary(memory, .plus, .u32(UInt32(bitPattern: number) >> 2 &+ plus))
        } else {
            let place = Expression.binary(WGSL.unsigned(offset), .right, .u32(2))
            at = .binary(memory, .plus, plus == 0 ? place : .binary(place, .plus, .u32(plus)))
        }
        return .element(.name(WGSL.heap), at)
    }

    private mutating func outside(_ from: String, _ name: String, _ arguments: [Expression], _ out: inout [Statement]) throws(Error) {
        switch (from, name, arguments.count) {
        case ("shader", "load", 2):
            let memory = try buffer(arguments[0])
            try make(.i32, WGSL.signed(word(memory, arguments[1], &out)), &out)
        case ("shader", "store", 3):
            let memory = try buffer(arguments[0])
            out.append(.assign(word(memory, arguments[1], &out), WGSL.unsigned(arguments[2])))
        case ("shader", "load_wide", 2):
            let memory = try buffer(arguments[0])
            try make(.i64, .construct(WGSL.wide, [word(memory, arguments[1], &out), word(memory, arguments[1], plus: 1, &out)]), &out)
        case ("shader", "store_wide", 3):
            let memory = try buffer(arguments[0])
            out.append(.assign(word(memory, arguments[1], &out), .member(arguments[2], "x")))
            out.append(.assign(word(memory, arguments[1], plus: 1, &out), .member(arguments[2], "y")))
        case ("shader", "load_byte", 2), ("shader", "store_byte", 3):
            let memory = try buffer(arguments[0])
            let offset = WGSL.unsigned(arguments[1])
            let shift = Expression.binary(.binary(offset, .and, .u32(3)), .left, .u32(3))
            let place = word(memory, arguments[1], &out)
            if name == "load_byte" {
                try make(.i32, WGSL.signed(.binary(.binary(place, .right, shift), .and, .u32(255))), &out)
            } else {
                let cleared = Expression.binary(place, .and, .unary(.complement, .binary(.u32(255), .left, shift)))
                out.append(.assign(place, .binary(cleared, .or, .binary(.binary(WGSL.unsigned(arguments[2]), .and, .u32(255)), .left, shift))))
            }
        case ("shader", "local", 2):
            let number = try constant(arguments[0])
            arrays[number] = max(arrays[number] ?? 0, try constant(arguments[1]))
            for place in 0..<UInt32(arrays[number] ?? 0) { out.append(.assign(.element(.name("shader_local\(number)"), .u32(place)), .u32(0))) }
        case ("shader", "local_load", 2):
            let number = try constant(arguments[0])
            try make(.i32, WGSL.signed(.element(.name("shader_local\(number)"), WGSL.unsigned(arguments[1]))), &out)
        case ("shader", "local_store", 3):
            let number = try constant(arguments[0])
            out.append(.assign(.element(.name("shader_local\(number)"), WGSL.unsigned(arguments[1])), WGSL.unsigned(arguments[2])))
        // A kernel's lanes are one: each place of a row's grid does the row's work alone.
        case ("shader", "lane", 0): push(.i32, .i32(0))
        case ("shader", "lanes", 0): push(.i32, .i32(1))
        case ("shader", "barrier", 0): break
        case ("shader", "prefix", 1), ("shader", "final", 1): push(.f32, arguments[0])
        case ("shader", "surface", 6):
            surface = true
            let place = Expression.construct(.vector(.u32, 2), arguments[4...].map(WGSL.unsigned))
            let vector = Expression.construct(.vector(.f32, 4), Array(arguments[..<4]))
            out.append(.call("textureStore", [.name(WGSL.surface), place, vector]))
        case ("shader", "exp", 1), ("shader", "sin", 1), ("shader", "cos", 1), ("shader", "atan2", 2), ("shader", "pow", 2):
            try make(.f32, .call(name, kept(arguments)), &out)
        case ("env", "powf", 2), ("env", "atan2f", 2), ("env", "tanf", 1), ("env", "atanf", 1):
            try make(.f32, .call(String(name.dropLast()), kept(arguments)), &out)
        case ("env", "roundf", 1): try make(.f32, call(.round, arguments), &out)
        case ("env", "fmodf", 2): try make(.f32, .binary(kept(arguments[0]), .remainder, arguments[1]), &out)
        case (_, "__extendhfsf2", 1):
            try make(.f32, .member(.call("unpack2x16float", [WGSL.unsigned(arguments[0])]), "x"), &out)
        case (_, "__truncsfhf2", 1):
            let packed = Expression.call("pack2x16float", [.construct(.vector(.f32, 2), [arguments[0], .f32(0)])])
            try make(.i32, WGSL.signed(.binary(packed, .and, .u32(0xFFFF))), &out)
        default: throw .imported(module: from, name: name)
        }
    }

    /// An `f32` operand as it is, but a constant read at run time, so that no call on constants alone is worked
    /// out when the text is compiled.
    mutating func kept(_ expression: Expression) -> Expression {
        guard case .f32 = expression else { return expression }
        return call(.keepFloat, [expression])
    }

    mutating func kept(_ expressions: [Expression]) -> [Expression] {
        var all: [Expression] = []
        for expression in expressions { all.append(kept(expression)) }
        return all
    }
}
