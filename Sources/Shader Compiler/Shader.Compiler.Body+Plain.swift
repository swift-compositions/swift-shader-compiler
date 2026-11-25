internal import Metal_Standard
internal import Shader
internal import W3C_WebAssembly

extension Shader.Compiler.Body {
    /// Writes an instruction that neither opens a block nor leaves one.
    mutating func plain(_ instruction: Instruction, _ out: inout [Metal.Statement]) throws(Error) {
        switch instruction {
        case .nop: break
        case .drop: _ = try pop()
        case .select, .selectOf:
            let condition = try pop(.i32)
            let second = try pop()
            guard let value = stack.last?.value else { throw .malformed(function: index) }
            let first = try pop()
            try make(value, .conditional(.binary(condition, .unequal, .uint(0)), first, second), &out)
        case .localGet(let number):
            guard locals.indices.contains(number) else { throw .malformed(function: index) }
            push(locals[number], .name("l\(number)"))
        case .localSet(let number): try set(number, try pop(), &out)
        case .localTee(let number):
            guard let entry = stack.last else { throw .malformed(function: index) }
            _ = try pop()
            try set(number, entry.expression, &out)
            push(entry.value, .name("l\(number)"))
        case .globalGet(let number):
            guard module.globals.indices.contains(number) else { throw .malformed(function: index) }
            try make(module.globals[number].kind.value, .member(Shader.Compiler.Unit.state, "g\(number)"), &out)
        case .globalSet(let number): out.append(.assign(.member(Shader.Compiler.Unit.state, "g\(number)"), try pop()))
        case .i32(let number): push(.i32, .convert(.int, [.uint(UInt32(bitPattern: number))]))
        case .i64(let number): push(.i64, .convert(.long, [.ulong(UInt64(bitPattern: number))]))
        case .f32(let bits): push(.f32, .float(bits))
        case .f64: throw .value(.f64, function: index)
        case .load(let load, let address): try self.load(load, address, &out)
        case .store(let store, let address): try self.store(store, address, &out)
        case .memoryCopy: try fill(&out, copying: true)
        case .memoryFill: try fill(&out, copying: false)
        case .numeric(let numeric): try self.numeric(numeric, &out)
        case .saturating(let saturating):
            let value = try pop(.f32)
            switch saturating {
            case .i32TruncSatF32S: try make(.i32, .convert(.int, [value]), &out)
            case .i32TruncSatF32U: try make(.i32, .convert(.int, [.convert(.uint, [value])]), &out)
            case .i64TruncSatF32S: try make(.i64, .convert(.long, [value]), &out)
            case .i64TruncSatF32U: try make(.i64, .convert(.long, [.convert(.ulong, [value])]), &out)
            default: throw .value(.f64, function: index)
            }
        case .call(let callee): try call(callee, &out)
        default: throw .instruction("\(instruction)", function: index)
        }
    }

    private mutating func set(_ number: Int, _ value: Metal.Expression, _ out: inout [Metal.Statement]) throws(Error) {
        guard locals.indices.contains(number) else { throw .malformed(function: index) }
        try keep(local: number, &out)
        if value != .name("l\(number)") { out.append(.assign(.name("l\(number)"), value)) }
    }

    private mutating func arguments(_ count: Int) throws(Error) -> [Metal.Expression] {
        guard stack.count >= count else { throw .malformed(function: index) }
        defer { stack.removeLast(count) }
        return stack.suffix(count).map(\.expression)
    }

    private mutating func call(_ callee: Int, _ out: inout [Metal.Statement]) throws(Error) {
        let imported = module.imported
        guard let signature = module.signature(of: callee) else { throw .malformed(function: index) }
        let arguments = try arguments(signature.parameters.count)
        guard !imported.indices.contains(callee) else {
            try outside(imported[callee].module, imported[callee].name, arguments, &out)
            return
        }
        use.calls.insert(callee)
        let call = Metal.Expression.call(Shader.Compiler.Unit.name(callee), [Shader.Compiler.Unit.state] + arguments)
        if let result = signature.results.first {
            try make(result, call, &out)
        } else {
            out.append(.evaluate(call))
        }
    }

    /// A constant argument's number.
    private func constant(_ expression: Metal.Expression?) throws(Error) -> Int32 {
        guard case .convert(.int, let values)? = expression, case .uint(let bits)? = values.first else { throw .constant(function: index) }
        return Int32(bitPattern: bits)
    }

    private mutating func outside(_ from: String, _ name: String, _ arguments: [Metal.Expression], _ out: inout [Metal.Statement]) throws(Error) {
        func word(_ pointer: String) -> Metal.Expression {
            if case .convert(.int, let values) = arguments[1], case .uint(let offset)? = values.first {
                return .element(.member(Shader.Compiler.Unit.state, pointer), .uint(offset >> 2))
            }
            return .element(.member(Shader.Compiler.Unit.state, pointer), .binary(.convert(.uint, [arguments[1]]), .right, .uint(2)))
        }
        switch (from, name, arguments.count) {
        case ("shader", "load", 2):
            let buffer = try constant(arguments.first)
            use.reads.insert(buffer)
            try make(.i32, .convert(.int, [word("r\(buffer)")]), &out)
        case ("shader", "store", 3):
            let buffer = try constant(arguments.first)
            use.writes.insert(buffer)
            out.append(.assign(word("w\(buffer)"), .convert(.uint, [arguments[2]])))
        case ("shader", "result", 2):
            let component = try constant(arguments.first)
            use.results.insert(component)
            out.append(.assign(.member(Shader.Compiler.Unit.state, "result\(component)"), arguments[1]))
        case (_, "__extendhfsf2", 1):
            try make(.f32, .convert(.float, [.bits(.scalar(.half), .convert(.scalar(.ushort), [arguments[0]]))]), &out)
        case (_, "__truncsfhf2", 1):
            let bits = Metal.Expression.bits(.scalar(.ushort), .convert(.scalar(.half), [arguments[0]]))
            try make(.i32, .convert(.int, [.convert(.uint, [bits])]), &out)
        default: throw .imported(module: from, name: name)
        }
    }
}
