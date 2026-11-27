internal import Shader
internal import W3C_WGSL
internal import W3C_WebAssembly

extension Shader.Compiler.WGSL.Body {
    mutating func numeric(_ numeric: Instruction.Numeric, _ out: inout [Statement]) throws(Error) {
        switch numeric {
        case .i32Eqz: try unary(.i32, .i32, &out) { WGSL.number(.binary($0, .equal, .i32(0))) }
        case .i64Eqz:
            try unary(.i64, .i32, &out) { WGSL.number(.binary(.binary(.member($0, "x"), .or, .member($0, "y")), .equal, .u32(0))) }
        case .i32Eq, .i32Ne, .i32LtS, .i32LtU, .i32GtS, .i32GtU, .i32LeS, .i32LeU, .i32GeS, .i32GeU:
            try narrowComparison(Int(numeric.rawValue - Instruction.Numeric.i32Eq.rawValue), &out)
        case .i64Eq, .i64Ne, .i64LtS, .i64LtU, .i64GtS, .i64GtU, .i64LeS, .i64LeU, .i64GeS, .i64GeU:
            try wideComparison(Int(numeric.rawValue - Instruction.Numeric.i64Eq.rawValue), &out)
        case .f32Eq, .f32Ne, .f32Lt, .f32Gt, .f32Le, .f32Ge:
            let signs: [Expression.Binary] = [.equal, .unequal, .less, .greater, .atMost, .atLeast]
            let sign = signs[Int(numeric.rawValue - Instruction.Numeric.f32Eq.rawValue)]
            let second = try pop(.f32)
            let first = kept(try pop(.f32))
            try make(.i32, WGSL.number(.binary(first, sign, second)), &out)
        case .i32Clz: try unary(.i32, .i32, &out) { WGSL.signed(.call("countLeadingZeros", [WGSL.unsigned($0)])) }
        case .i32Ctz: try unary(.i32, .i32, &out) { WGSL.signed(.call("countTrailingZeros", [WGSL.unsigned($0)])) }
        case .i32Popcnt: try unary(.i32, .i32, &out) { WGSL.signed(.call("countOneBits", [WGSL.unsigned($0)])) }
        case .i32Add, .i32Sub, .i32Mul, .i32DivS, .i32DivU, .i32RemS, .i32RemU, .i32And, .i32Or, .i32Xor, .i32Shl, .i32ShrS, .i32ShrU,
            .i32Rotl, .i32Rotr:
            try narrow(numeric, &out)
        case .i64Clz: try wideCall(.leading, 1, &out)
        case .i64Ctz: try wideCall(.trailing, 1, &out)
        case .i64Popcnt:
            try unary(.i64, .i64, &out) {
                .construct(WGSL.wide, [.binary(.call("countOneBits", [.member($0, "x")]), .plus, .call("countOneBits", [.member($0, "y")])), .u32(0)])
            }
        case .i64Add, .i64Sub, .i64Mul, .i64And, .i64Or, .i64Xor, .i64Shl, .i64ShrS, .i64ShrU, .i64Rotl, .i64Rotr:
            try wide(numeric, &out)
        case .i64DivS, .i64DivU, .i64RemS, .i64RemU: throw .instruction("\(numeric)", function: index)
        case .f32Abs: try unary(.f32, .f32, &out) { .bitcast(.f32, .binary(.bitcast(.u32, $0), .and, .u32(0x7FFF_FFFF))) }
        case .f32Neg: try unary(.f32, .f32, &out) { .bitcast(.f32, .binary(.bitcast(.u32, $0), .xor, .u32(0x8000_0000))) }
        case .f32Ceil: try floatCall("ceil", &out)
        case .f32Floor: try floatCall("floor", &out)
        case .f32Trunc: try floatCall("trunc", &out)
        // WebAssembly's nearest and WGSL's round both take a half to the even neighbour.
        case .f32Nearest: try floatCall("round", &out)
        case .f32Sqrt: try floatCall("sqrt", &out)
        case .f32Add: try floating(&out) { .binary($0, .plus, $1) }
        case .f32Sub: try floating(&out) { .binary($0, .minus, $1) }
        case .f32Mul: try floating(&out) { .binary($0, .times, $1) }
        case .f32Div: try floating(&out) { .binary($0, .over, $1) }
        case .f32Min:
            helpers.insert(.least)
            try floating(&out) { .call(Helper.least.rawValue, [$0, $1]) }
        case .f32Max:
            helpers.insert(.most)
            try floating(&out) { .call(Helper.most.rawValue, [$0, $1]) }
        case .f32Copysign:
            try floating(&out) {
                .bitcast(.f32, .binary(.binary(.bitcast(.u32, $0), .and, .u32(0x7FFF_FFFF)), .or, .binary(.bitcast(.u32, $1), .and, .u32(0x8000_0000))))
            }
        default: try conversion(numeric, &out)
        }
    }

    private mutating func unary(_ from: Value, _ to: Value, _ out: inout [Statement], _ worked: (Expression) -> Expression) throws(Error) {
        let value = try pop(from)
        try make(to, worked(from == .f32 ? kept(value) : from == .i32 ? keptNarrow(value) : value), &out)
    }

    private mutating func floatCall(_ name: String, _ out: inout [Statement]) throws(Error) {
        let value = kept(try pop(.f32))
        try make(.f32, .call(name, [value]), &out)
    }

    private mutating func floating(_ out: inout [Statement], _ worked: (Expression, Expression) -> Expression) throws(Error) {
        let second = try pop(.f32)
        let first = kept(try pop(.f32))
        try make(.f32, worked(first, second), &out)
    }

    /// An `i32` operand as it is, but a constant read at run time.
    private mutating func keptNarrow(_ expression: Expression) -> Expression {
        guard case .i32 = expression else { return expression }
        return call(.keep, [expression])
    }

    private mutating func narrowComparison(_ place: Int, _ out: inout [Statement]) throws(Error) {
        let signs: [Expression.Binary] = [.equal, .unequal, .less, .less, .greater, .greater, .atMost, .atMost, .atLeast, .atLeast]
        let unsigned = place > 1 && place % 2 == 1
        let second = try pop(.i32)
        let first = keptNarrow(try pop(.i32))
        let compared: Expression =
            unsigned ? .binary(WGSL.unsigned(first), signs[place], WGSL.unsigned(second)) : .binary(first, signs[place], second)
        try make(.i32, WGSL.number(compared), &out)
    }

    private mutating func wideComparison(_ place: Int, _ out: inout [Statement]) throws(Error) {
        let second = try pop(.i64)
        let first = try pop(.i64)
        let equal = Expression.binary(.binary(.member(first, "x"), .equal, .member(second, "x")), .both, .binary(.member(first, "y"), .equal, .member(second, "y")))
        let less: Helper = place % 2 == 0 ? .lessSigned : .less
        let compared: Expression =
            switch place {
            case 0: equal
            case 1: .unary(.not, equal)
            case 2, 3: call(less, [first, second])
            case 4, 5: call(less, [second, first])
            case 6, 7: .unary(.not, call(less, [second, first]))
            default: .unary(.not, call(less, [first, second]))
            }
        try make(.i32, WGSL.number(compared), &out)
    }

    private mutating func narrow(_ numeric: Instruction.Numeric, _ out: inout [Statement]) throws(Error) {
        let second = try pop(.i32)
        let first = try pop(.i32)
        if let a = Self.number(first), let b = Self.number(second), let whole = Self.worked(numeric, a, b) {
            push(.i32, .i32(whole))
            return
        }
        let x = WGSL.unsigned(first)
        let y = WGSL.unsigned(second)
        let count = Expression.binary(y, .and, .u32(31))
        let worked: Expression =
            switch numeric {
            case .i32Add: WGSL.signed(.binary(x, .plus, y))
            case .i32Sub: WGSL.signed(.binary(x, .minus, y))
            case .i32Mul: WGSL.signed(.binary(x, .times, y))
            case .i32DivS: .binary(first, .over, second)
            case .i32RemS: .binary(first, .remainder, second)
            case .i32DivU: WGSL.signed(.binary(x, .over, y))
            case .i32RemU: WGSL.signed(.binary(x, .remainder, y))
            case .i32And: WGSL.signed(.binary(x, .and, y))
            case .i32Or: WGSL.signed(.binary(x, .or, y))
            case .i32Xor: WGSL.signed(.binary(x, .xor, y))
            case .i32Shl: WGSL.signed(.binary(x, .left, count))
            case .i32ShrS: .binary(first, .right, count)
            case .i32ShrU: WGSL.signed(.binary(x, .right, count))
            case .i32Rotl: WGSL.signed(.binary(.binary(x, .left, count), .or, .binary(x, .right, .binary(.binary(.u32(32), .minus, count), .and, .u32(31)))))
            default: WGSL.signed(.binary(.binary(x, .right, count), .or, .binary(x, .left, .binary(.binary(.u32(32), .minus, count), .and, .u32(31)))))
            }
        let address =
            stacked(first) != stacked(second)
            && (numeric == .i32Add || numeric == .i32Sub || (numeric == .i32Or && (Self.number(first) ?? Self.number(second)) != nil))
        try make(.i32, worked, &out)
        if address { stacked.insert("t\(made)") }
    }

    /// What an operation on two constants gives, as WebAssembly works it, or nil where it would trap.
    private static func worked(_ numeric: Instruction.Numeric, _ a: Int32, _ b: Int32) -> Int32? {
        let x = UInt32(bitPattern: a)
        let y = UInt32(bitPattern: b)
        let count = y & 31
        switch numeric {
        case .i32Add: return a &+ b
        case .i32Sub: return a &- b
        case .i32Mul: return a &* b
        case .i32DivS: return b == 0 || (a == .min && b == -1) ? nil : a / b
        case .i32RemS: return b == 0 ? nil : b == -1 ? 0 : a % b
        case .i32DivU: return y == 0 ? nil : Int32(bitPattern: x / y)
        case .i32RemU: return y == 0 ? nil : Int32(bitPattern: x % y)
        case .i32And: return a & b
        case .i32Or: return a | b
        case .i32Xor: return a ^ b
        case .i32Shl: return Int32(bitPattern: x << count)
        case .i32ShrS: return a >> count
        case .i32ShrU: return Int32(bitPattern: x >> count)
        case .i32Rotl: return Int32(bitPattern: x << count | x >> ((32 - count) & 31))
        case .i32Rotr: return Int32(bitPattern: x >> count | x << ((32 - count) & 31))
        default: return nil
        }
    }

    private mutating func wideCall(_ helper: Helper, _ count: Int, _ out: inout [Statement]) throws(Error) {
        var arguments: [Expression] = []
        for _ in 0..<count { arguments.insert(try pop(.i64), at: 0) }
        try make(.i64, call(helper, arguments), &out)
    }

    private mutating func wide(_ numeric: Instruction.Numeric, _ out: inout [Statement]) throws(Error) {
        let second = try pop(.i64)
        let first = try pop(.i64)
        if let a = WGSL.wideNumber(first), let b = WGSL.wideNumber(second) {
            let count = b & 63
            let whole: UInt64? =
                switch numeric {
                case .i64Add: a &+ b
                case .i64Sub: a &- b
                case .i64Mul: a &* b
                case .i64And: a & b
                case .i64Or: a | b
                case .i64Xor: a ^ b
                case .i64Shl: a << count
                case .i64ShrU: a >> count
                case .i64ShrS: UInt64(bitPattern: Int64(bitPattern: a) >> count)
                case .i64Rotl: a << count | a >> ((64 - count) & 63)
                case .i64Rotr: a >> count | a << ((64 - count) & 63)
                default: nil
                }
            if let whole {
                push(.i64, WGSL.wide(whole))
                return
            }
        }
        func parts(_ sign: Expression.Binary) -> Expression {
            .construct(WGSL.wide, [.binary(.member(first, "x"), sign, .member(second, "x")), .binary(.member(first, "y"), sign, .member(second, "y"))])
        }
        let count = Expression.member(second, "x")
        let worked: Expression
        switch numeric {
        case .i64Add: worked = call(.add, [first, second])
        case .i64Sub: worked = call(.subtract, [first, second])
        case .i64Mul: worked = call(.multiply, [first, second])
        case .i64And: worked = parts(.and)
        case .i64Or: worked = parts(.or)
        case .i64Xor: worked = parts(.xor)
        case .i64Shl: worked = call(.left, [first, count])
        case .i64ShrU: worked = call(.right, [first, count])
        case .i64ShrS: worked = call(.rightSigned, [first, count])
        case .i64Rotl, .i64Rotr:
            let back = Expression.binary(.binary(.u32(64), .minus, .binary(count, .and, .u32(63))), .and, .u32(63))
            let (one, other): (Helper, Helper) = numeric == .i64Rotl ? (.left, .right) : (.right, .left)
            let a = call(one, [first, count])
            let b = call(other, [first, back])
            worked = .construct(WGSL.wide, [.binary(.member(a, "x"), .or, .member(b, "x")), .binary(.member(a, "y"), .or, .member(b, "y"))])
        default: throw .instruction("\(numeric)", function: index)
        }
        try make(.i64, worked, &out)
    }

    private mutating func conversion(_ numeric: Instruction.Numeric, _ out: inout [Statement]) throws(Error) {
        switch numeric {
        case .i32WrapI64: try unary(.i64, .i32, &out) { WGSL.signed(.member($0, "x")) }
        case .i32TruncF32S: try unary(.f32, .i32, &out) { .construct(.i32, [$0]) }
        case .i32TruncF32U: try unary(.f32, .i32, &out) { WGSL.signed(.construct(.u32, [$0])) }
        case .i64ExtendI32S:
            let value = try pop(.i32)
            if let number = Self.number(value) {
                push(.i64, WGSL.wide(UInt64(bitPattern: Int64(number))))
            } else {
                try make(.i64, call(.extend, [value]), &out)
            }
        case .i64ExtendI32U:
            let value = try pop(.i32)
            if let number = Self.number(value) {
                push(.i64, WGSL.wide(UInt64(UInt32(bitPattern: number))))
            } else {
                try make(.i64, .construct(WGSL.wide, [WGSL.unsigned(value), .u32(0)]), &out)
            }
        case .i64TruncF32S:
            let value = try pop(.f32)
            try make(.i64, call(.truncate, [value]), &out)
        case .i64TruncF32U:
            let value = try pop(.f32)
            try make(.i64, call(.truncateUnsigned, [value]), &out)
        case .f32ConvertI32S: try unary(.i32, .f32, &out) { .construct(.f32, [$0]) }
        case .f32ConvertI32U: try unary(.i32, .f32, &out) { .construct(.f32, [WGSL.unsigned($0)]) }
        case .f32ConvertI64S:
            let value = try pop(.i64)
            try make(.f32, call(.convert, [value]), &out)
        case .f32ConvertI64U:
            let value = try pop(.i64)
            try make(.f32, call(.convertUnsigned, [value]), &out)
        case .i32ReinterpretF32: try unary(.f32, .i32, &out) { .bitcast(.i32, $0) }
        case .f32ReinterpretI32: try unary(.i32, .f32, &out) { .bitcast(.f32, $0) }
        case .i32Extend8S: try unary(.i32, .i32, &out) { .binary(.binary($0, .left, .u32(24)), .right, .u32(24)) }
        case .i32Extend16S: try unary(.i32, .i32, &out) { .binary(.binary($0, .left, .u32(16)), .right, .u32(16)) }
        case .i64Extend8S, .i64Extend16S, .i64Extend32S:
            let value = try pop(.i64)
            let shift: UInt32 = numeric == .i64Extend8S ? 24 : numeric == .i64Extend16S ? 16 : 0
            let low = Expression.bitcast(.i32, .member(value, "x"))
            try make(.i64, call(.extend, [shift == 0 ? low : .binary(.binary(low, .left, .u32(shift)), .right, .u32(shift))]), &out)
        default: throw .value(.f64, function: index)
        }
    }
}
