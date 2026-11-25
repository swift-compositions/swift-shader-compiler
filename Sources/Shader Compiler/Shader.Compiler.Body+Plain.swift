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
            let address = stacked(first) && stacked(second)
            defer { if address { stacked.insert("t\(made)") } }
            try make(value, .conditional(.binary(condition, .unequal, .uint(0)), first, second), &out)
        case .localGet(let number):
            guard locals.indices.contains(number) else { throw .malformed(function: index) }
            if let fixed = fixed[number] {
                push(.i32, .convert(.int, [.uint(UInt32(bitPattern: fixed))]))
            } else {
                push(locals[number], .name("l\(number)"))
            }
        case .localSet(let number): try set(number, try pop(), &out)
        case .localTee(let number):
            guard let entry = stack.last else { throw .malformed(function: index) }
            _ = try pop()
            try set(number, entry.expression, &out)
            if let whole = fixed[number] {
                push(.i32, .convert(.int, [.uint(UInt32(bitPattern: whole))]))
            } else {
                push(entry.value, .name("l\(number)"))
            }
        case .globalGet(let number):
            guard module.globals.indices.contains(number) else { throw .malformed(function: index) }
            try make(module.globals[number].kind.value, .member(Shader.Compiler.Unit.state, "g\(number)"), &out)
            if number == 0 { stacked.insert("t\(made)") }
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
        fixed[number] = locals[number] == .i32 ? Self.number(value) : nil
        let address = stacked(value)
        try keep(local: number, &out)
        if address { stacked.insert("l\(number)") } else { stacked.remove("l\(number)") }
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
        let its = surveyed[callee]?.fixed ?? []
        let called = Shader.Compiler.Key(index: callee, constants: key.constants.intersection(its))
        use.calls.insert(called)
        var given: [Metal.Expression] = []
        for (place, argument) in arguments.enumerated() {
            if let access = numbering[callee]?[place] {
                given.append(try buffer(argument, access))
            } else {
                given.append(argument)
            }
        }
        let call = Metal.Expression.call(called.name, [Shader.Compiler.Unit.state] + given)
        if let result = signature.results.first {
            try make(result, call, &out)
        } else {
            out.append(.evaluate(call))
        }
    }

    /// The number a constant is.
    static func number(_ expression: Metal.Expression?) -> Int32? {
        guard case .convert(.int, let values)? = expression, values.count == 1, case .uint(let bits)? = values.first else { return nil }
        return Int32(bitPattern: bits)
    }

    private func constant(_ expression: Metal.Expression?) throws(Error) -> Int32 {
        guard let number = Self.number(expression) else { throw .constant(function: index) }
        return number
    }

    /// The memory a number stands for: the state's, or a parameter's.
    private mutating func buffer(_ expression: Metal.Expression?, _ access: Shader.Compiler.Access) throws(Error) -> Metal.Expression {
        if let number = Self.number(expression) {
            if access.written { use.writes.insert(number) } else { use.reads.insert(number) }
            return .member(Shader.Compiler.Unit.state, access.written ? "w\(number)" : "r\(number)")
        }
        guard !entry, case .name(let name)? = expression, name.hasPrefix("l"), let local = Int(name.dropFirst()),
            let signature = module.signature(of: index), signature.parameters.indices.contains(local),
            !module.functions[index - module.imported.count].body.assigned.contains(local)
        else { throw .constant(function: index) }
        numbered[local, default: .init()].written = access.written || numbered[local]?.written ?? false
        return .name(name)
    }

    private mutating func outside(_ from: String, _ name: String, _ arguments: [Metal.Expression], _ out: inout [Metal.Statement]) throws(Error) {
        func word(_ pointer: Metal.Expression) -> Metal.Expression {
            if case .convert(.int, let values) = arguments[1], case .uint(let offset)? = values.first {
                return .element(pointer, .uint(offset >> 2))
            }
            return .element(pointer, .binary(.convert(.uint, [arguments[1]]), .right, .uint(2)))
        }
        func byte(_ pointer: Metal.Expression, constant: Bool) -> Metal.Expression {
            return .element(
                .pointer(.pointer(.scalar(.uchar), .device, constant: constant), pointer),
                .convert(.uint, [arguments[1]])
            )
        }
        switch (from, name, arguments.count) {
        case ("shader", "load", 2):
            if let number = Self.number(arguments[0]), Self.number(arguments[1]) != nil {
                let constant = key.constants.contains(number)
                use.fixed.insert(number)
                if constant { use.constants.insert(number) } else if surveyed[index] != nil { use.reads.insert(number) }
                try make(.i32, .convert(.int, [word(.member(Shader.Compiler.Unit.state, constant ? "c\(number)" : "r\(number)"))]), &out)
                return
            }
            let memory = try buffer(arguments.first, .init())
            try make(.i32, .convert(.int, [word(memory)]), &out)
        case ("shader", "store", 3):
            let memory = try buffer(arguments.first, .init(written: true))
            out.append(.assign(word(memory), .convert(.uint, [arguments[2]])))
        case ("shader", "result", 2):
            let component = try constant(arguments.first)
            use.results.insert(component)
            out.append(.assign(.member(Shader.Compiler.Unit.state, "result\(component)"), arguments[1]))
        case ("shader", "load_wide", 2):
            let place: Metal.Expression
            let memory: Metal.Expression
            var space = Metal.Space.device
            if let number = Self.number(arguments[0]), let offset = Self.number(arguments[1]) {
                let constant = key.constants.contains(number)
                use.fixed.insert(number)
                if constant { use.constants.insert(number) } else if surveyed[index] != nil { use.reads.insert(number) }
                memory = .member(Shader.Compiler.Unit.state, constant ? "c\(number)" : "r\(number)")
                if constant { space = .constant }
                place = .uint(UInt32(bitPattern: offset) >> 3)
            } else {
                memory = try buffer(arguments.first, .init())
                place = .binary(.convert(.uint, [arguments[1]]), .right, .uint(3))
            }
            let pair = Metal.Kind.vector(.uint, 2)
            let wide = Metal.Expression.element(.pointer(.pointer(pair, space, constant: space == .device), memory), place)
            try make(.i64, .convert(.long, [.bits(.ulong, wide)]), &out)
        case ("shader", "store_wide", 3):
            let memory = try buffer(arguments.first, .init(written: true))
            let place = Metal.Expression.binary(.convert(.uint, [arguments[1]]), .right, .uint(3))
            let pair = Metal.Kind.vector(.uint, 2)
            out.append(
                .assign(.element(.pointer(.pointer(pair, .device), memory), place), .bits(pair, .convert(.ulong, [arguments[2]])))
            )
        case ("shader", "load_byte", 2):
            let memory = try buffer(arguments.first, .init())
            try make(.i32, .convert(.int, [byte(memory, constant: true)]), &out)
        case ("shader", "store_byte", 3):
            let memory = try buffer(arguments.first, .init(written: true))
            out.append(.assign(byte(memory, constant: false), .convert(.scalar(.uchar), [arguments[2]])))
        case ("shader", "lane", 0), ("shader", "lanes", 0):
            use.lanes = true
            try make(.i32, .convert(.int, [.member(Shader.Compiler.Unit.state, name)]), &out)
        case ("shader", "barrier", 0):
            out.append(.evaluate(.call("simdgroup_barrier", [.name("mem_flags::mem_device")])))
        case ("shader", "prefix", 1): try make(.f32, .call("simd_prefix_inclusive_sum", arguments), &out)
        case ("shader", "final", 1):
            use.lanes = true
            let last = Metal.Expression.binary(.member(Shader.Compiler.Unit.state, "lanes"), .minus, .uint(1))
            try make(.f32, .call("simd_broadcast", arguments + [.convert(.scalar(.ushort), [last])]), &out)
        case ("shader", "surface", 6):
            use.surface = true
            let place = Metal.Expression.convert(.vector(.uint, 2), arguments[4...].map { .convert(.uint, [$0]) })
            let vector = Metal.Expression.convert(.vector(.float, 4), Array(arguments[..<4]))
            out.append(.evaluate(.call("\(Metal.Expression.member(Shader.Compiler.Unit.state, "surface")).write", [vector, place])))
        case ("shader", "exp", 1), ("shader", "sin", 1), ("shader", "cos", 1), ("shader", "atan2", 2), ("shader", "pow", 2):
            try make(.f32, .call(name, arguments), &out)
        case ("env", "powf", 2), ("env", "atan2f", 2), ("env", "tanf", 1), ("env", "atanf", 1), ("env", "roundf", 1), ("env", "fmodf", 2):
            try make(.f32, .call(String(name.dropLast()), arguments), &out)
        case (_, "__extendhfsf2", 1):
            try make(.f32, .convert(.float, [.bits(.scalar(.half), .convert(.scalar(.ushort), [arguments[0]]))]), &out)
        case (_, "__truncsfhf2", 1):
            let bits = Metal.Expression.bits(.scalar(.ushort), .convert(.scalar(.half), [arguments[0]]))
            try make(.i32, .convert(.int, [.convert(.uint, [bits])]), &out)
        default: throw .imported(module: from, name: name)
        }
    }
}
