internal import Metal_Standard
internal import Shader
internal import W3C_WebAssembly

extension Shader.Compiler.Body {
    typealias Helper = Shader.Compiler.Helper

    private mutating func call(_ helper: Helper, _ arguments: [Metal.Expression]) -> Metal.Expression {
        use.helpers.insert(helper)
        return .call(helper.rawValue, [Shader.Compiler.Unit.state] + arguments)
    }

    /// An address, with a constant added.
    private func at(_ base: Metal.Expression, _ offset: UInt32) -> Metal.Expression {
        let base = Metal.Expression.convert(.uint, [base])
        return offset == 0 ? base : .binary(base, .plus, .uint(offset))
    }

    /// The bytes at an address as one number, lowest first.
    private mutating func bytes(_ count: UInt32, _ base: Metal.Expression, _ address: Instruction.Address) -> Metal.Expression {
        if count == 4, address.alignment >= 2 { return call(.load, [at(base, address.offset)]) }
        var whole: Metal.Expression?
        for place in 0..<count {
            let byte = call(.loadByte, [at(base, address.offset &+ place)])
            let moved = place == 0 ? byte : Metal.Expression.binary(byte, .left, .uint(8 * place))
            whole = whole.map { .binary($0, .or, moved) } ?? moved
        }
        return whole ?? .uint(0)
    }

    private mutating func double(_ base: Metal.Expression, _ address: Instruction.Address) -> Metal.Expression {
        let low = bytes(4, base, address)
        let high = bytes(4, base, .init(offset: address.offset &+ 4, alignment: address.alignment))
        return .convert(.long, [.binary(.convert(.ulong, [low]), .or, .binary(.convert(.ulong, [high]), .left, .uint(32)))])
    }

    mutating func load(_ load: Instruction.Load, _ address: Instruction.Address, _ out: inout [Metal.Statement]) throws(Error) {
        let base = try pop(.i32)
        func signed(_ scalar: Metal.Scalar, _ bits: Metal.Expression) -> Metal.Expression { .convert(.scalar(scalar), [bits]) }
        switch load {
        case .i32Load: try make(.i32, .convert(.int, [bytes(4, base, address)]), &out)
        case .i64Load: try make(.i64, double(base, address), &out)
        case .f32Load: try make(.f32, .bits(.float, bytes(4, base, address)), &out)
        case .f64Load: throw .value(.f64, function: index)
        case .i32Load8S: try make(.i32, .convert(.int, [signed(.char, bytes(1, base, address))]), &out)
        case .i32Load8U: try make(.i32, .convert(.int, [bytes(1, base, address)]), &out)
        case .i32Load16S: try make(.i32, .convert(.int, [signed(.short, bytes(2, base, address))]), &out)
        case .i32Load16U: try make(.i32, .convert(.int, [bytes(2, base, address)]), &out)
        case .i64Load8S: try make(.i64, .convert(.long, [signed(.char, bytes(1, base, address))]), &out)
        case .i64Load8U: try make(.i64, .convert(.long, [bytes(1, base, address)]), &out)
        case .i64Load16S: try make(.i64, .convert(.long, [signed(.short, bytes(2, base, address))]), &out)
        case .i64Load16U: try make(.i64, .convert(.long, [bytes(2, base, address)]), &out)
        case .i64Load32S: try make(.i64, .convert(.long, [signed(.int, bytes(4, base, address))]), &out)
        case .i64Load32U: try make(.i64, .convert(.long, [bytes(4, base, address)]), &out)
        }
    }

    mutating func store(_ store: Instruction.Store, _ address: Instruction.Address, _ out: inout [Metal.Statement]) throws(Error) {
        guard let value = stack.last?.value else { throw .malformed(function: index) }
        let number = try pop()
        let base = try pop(.i32)
        func put(_ count: UInt32, _ bits: Metal.Expression, _ address: Instruction.Address, _ body: inout Self) {
            if count == 4, address.alignment >= 2 {
                out.append(.evaluate(body.call(.store, [body.at(base, address.offset), bits])))
            } else {
                for place in 0..<count {
                    let byte = place == 0 ? bits : Metal.Expression.binary(bits, .right, .uint(8 * place))
                    out.append(.evaluate(body.call(.storeByte, [body.at(base, address.offset &+ place), byte])))
                }
            }
        }
        let bits = value == .f32 ? Metal.Expression.bits(.uint, number) : .convert(.uint, [number])
        switch store {
        case .i32Store, .f32Store, .i64Store32: put(4, bits, address, &self)
        case .i64Store:
            put(4, bits, address, &self)
            let high = Metal.Expression.convert(.uint, [.binary(.convert(.ulong, [number]), .right, .uint(32))])
            put(4, high, .init(offset: address.offset &+ 4, alignment: address.alignment), &self)
        case .f64Store: throw .value(.f64, function: index)
        case .i32Store8, .i64Store8: put(1, bits, address, &self)
        case .i32Store16, .i64Store16: put(2, bits, address, &self)
        }
    }

    /// Copies bytes or fills them with one.
    mutating func fill(_ out: inout [Metal.Statement], copying: Bool) throws(Error) {
        let count = try pop(.i32)
        let from = try pop(.i32)
        let to = try pop(.i32)
        // A copy that reaches over itself would have to run backwards.
        made += 1
        let name = Metal.Expression.name("t\(made)")
        out.append(.declare(.uint, "t\(made)", .uint(0)))
        func place(_ base: Metal.Expression) -> Metal.Expression { .binary(.convert(.uint, [base]), .plus, name) }
        var body: [Metal.Statement] = []
        if copying {
            let length = Metal.Expression.convert(.uint, [count])
            let backwards = Metal.Expression.binary(.convert(.uint, [from]), .less, .convert(.uint, [to]))
            let step = Metal.Expression.conditional(backwards, .binary(.binary(length, .minus, .uint(1)), .minus, name), name)
            let source = call(.loadByte, [.binary(.convert(.uint, [from]), .plus, step)])
            body.append(.evaluate(call(.storeByte, [.binary(.convert(.uint, [to]), .plus, step), source])))
        } else {
            body.append(.evaluate(call(.storeByte, [place(to), .convert(.uint, [from])])))
        }
        body.append(.assign(name, .binary(name, .plus, .uint(1))))
        out.append(.while(.binary(name, .less, .convert(.uint, [count])), body))
    }
}
