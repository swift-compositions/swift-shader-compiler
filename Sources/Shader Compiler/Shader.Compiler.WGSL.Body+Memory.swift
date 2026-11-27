internal import Shader
internal import W3C_WGSL
internal import W3C_WebAssembly

extension Shader.Compiler.WGSL.Body {
    /// The word at an address, which is checked unless it is known to lie in the stack.
    private mutating func word(_ base: Expression, _ offset: UInt32) -> Expression {
        call(stacked(base) ? .loadStack : .load, [at(base, offset)])
    }

    /// An address, with a constant added.
    private func at(_ base: Expression, _ offset: UInt32) -> Expression {
        if let number = Self.number(base) { return .u32(UInt32(bitPattern: number) &+ offset) }
        let base = WGSL.unsigned(base)
        return offset == 0 ? base : .binary(base, .plus, .u32(offset))
    }

    /// The bytes at an address as one number, lowest first.
    private mutating func bytes(_ count: UInt32, _ base: Expression, _ address: Instruction.Address) -> Expression {
        if count == 4, address.alignment >= 2 { return word(base, address.offset) }
        var whole: Expression?
        for place in 0..<count {
            let byte = call(.loadByte, [at(base, address.offset &+ place)])
            let moved = place == 0 ? byte : Expression.binary(byte, .left, .u32(8 * place))
            whole = whole.map { .binary($0, .or, moved) } ?? moved
        }
        return whole ?? .u32(0)
    }

    /// The low bits of a word as a signed number, its sign carried up.
    private static func extended(_ bits: Expression, _ width: UInt32) -> Expression {
        .binary(.bitcast(.i32, .binary(bits, .left, .u32(32 - width))), .right, .u32(32 - width))
    }

    mutating func load(_ load: Instruction.Load, _ address: Instruction.Address, _ out: inout [Statement]) throws(Error) {
        let base = try pop(.i32)
        func wide(_ low: Expression) -> Expression { .construct(WGSL.wide, [low, .u32(0)]) }
        switch load {
        case .i32Load: try make(.i32, WGSL.signed(bytes(4, base, address)), &out)
        case .i64Load:
            let low = bytes(4, base, address)
            let high = bytes(4, base, .init(offset: address.offset &+ 4, alignment: address.alignment))
            try make(.i64, .construct(WGSL.wide, [low, high]), &out)
        case .f32Load: try make(.f32, .bitcast(.f32, bytes(4, base, address)), &out)
        case .f64Load: throw .value(.f64, function: index)
        case .i32Load8S: try make(.i32, Self.extended(bytes(1, base, address), 8), &out)
        case .i32Load8U: try make(.i32, WGSL.signed(bytes(1, base, address)), &out)
        case .i32Load16S: try make(.i32, Self.extended(bytes(2, base, address), 16), &out)
        case .i32Load16U: try make(.i32, WGSL.signed(bytes(2, base, address)), &out)
        case .i64Load8S: try make(.i64, call(.extend, [Self.extended(bytes(1, base, address), 8)]), &out)
        case .i64Load8U: try make(.i64, wide(bytes(1, base, address)), &out)
        case .i64Load16S: try make(.i64, call(.extend, [Self.extended(bytes(2, base, address), 16)]), &out)
        case .i64Load16U: try make(.i64, wide(bytes(2, base, address)), &out)
        case .i64Load32S: try make(.i64, call(.extend, [WGSL.signed(bytes(4, base, address))]), &out)
        case .i64Load32U: try make(.i64, wide(bytes(4, base, address)), &out)
        }
    }

    mutating func store(_ store: Instruction.Store, _ address: Instruction.Address, _ out: inout [Statement]) throws(Error) {
        guard let value = stack.last?.value else { throw .malformed(function: index) }
        let number = try pop()
        let base = try pop(.i32)
        func put(_ count: UInt32, _ bits: Expression, _ address: Instruction.Address, _ body: inout Self) {
            if count == 4, address.alignment >= 2 {
                let helper: Helper = body.stacked(base) ? .storeStack : .store
                body.helpers.insert(helper)
                out.append(.call(helper.rawValue, [body.at(base, address.offset), bits]))
            } else {
                body.helpers.insert(.storeByte)
                for place in 0..<count {
                    let byte = place == 0 ? bits : Expression.binary(bits, .right, .u32(8 * place))
                    out.append(.call(Helper.storeByte.rawValue, [body.at(base, address.offset &+ place), byte]))
                }
            }
        }
        let bits: Expression =
            switch value {
            case .f32: .bitcast(.u32, number)
            case .i64: .member(number, "x")
            default: WGSL.unsigned(number)
            }
        switch store {
        case .i32Store, .f32Store, .i64Store32: put(4, bits, address, &self)
        case .i64Store:
            put(4, bits, address, &self)
            put(4, .member(number, "y"), .init(offset: address.offset &+ 4, alignment: address.alignment), &self)
        case .f64Store: throw .value(.f64, function: index)
        case .i32Store8, .i64Store8: put(1, bits, address, &self)
        case .i32Store16, .i64Store16: put(2, bits, address, &self)
        }
    }

    /// Copies bytes or fills them with one.
    mutating func fill(_ out: inout [Statement], copying: Bool) throws(Error) {
        let count = try pop(.i32)
        let from = try pop(.i32)
        let to = try pop(.i32)
        // A copy that reaches over itself would have to run backwards.
        made += 1
        let name = Expression.name("t\(made)")
        out.append(.var(.u32, "t\(made)", .u32(0)))
        func place(_ base: Expression) -> Expression { .binary(WGSL.unsigned(base), .plus, name) }
        if let whole = Self.number(count), whole % 4 == 0, whole <= 512, copying ? stacked(from) && stacked(to) : Self.number(from) == 0 && stacked(to) {
            // Values in the stack lie at multiples of four bytes.
            let words = (0..<UInt32(whole) / 4).map { $0 * 4 }
            var values: [Expression] = []
            for place in words {
                guard copying else {
                    values.append(.u32(0))
                    continue
                }
                made += 1
                out.append(.let("t\(made)", word(from, place)))
                values.append(.name("t\(made)"))
            }
            helpers.insert(.storeStack)
            for (place, value) in zip(words, values) { out.append(.call(Helper.storeStack.rawValue, [at(to, place), value])) }
            return
        }
        var body: [Statement] = [.if(.unary(.not, .binary(name, .less, WGSL.unsigned(count))), [.break])]
        helpers.insert(.storeByte)
        if copying {
            let length = WGSL.unsigned(count)
            let backwards = Expression.binary(WGSL.unsigned(from), .less, WGSL.unsigned(to))
            let step = Expression.call("select", [name, .binary(.binary(length, .minus, .u32(1)), .minus, name), backwards])
            let source = call(.loadByte, [.binary(WGSL.unsigned(from), .plus, step)])
            body.append(.call(Helper.storeByte.rawValue, [.binary(WGSL.unsigned(to), .plus, step), source]))
        } else {
            body.append(.call(Helper.storeByte.rawValue, [place(to), WGSL.unsigned(from)]))
        }
        body.append(.assign(name, .binary(name, .plus, .u32(1))))
        out.append(.loop(body))
    }
}
