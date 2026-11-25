internal import Metal_Standard
internal import Shader
internal import W3C_WebAssembly

extension Shader.Compiler.Body {
    /// An integer operation's width and its types.
    private struct Width {
        var value: Value
        var signed: Metal.Kind
        var unsigned: Metal.Kind
        var mask: UInt32

        static let narrow = Self(value: .i32, signed: .int, unsigned: .uint, mask: 31)
        static let wide = Self(value: .i64, signed: .long, unsigned: .ulong, mask: 63)
    }

    private mutating func integer(_ width: Width, _ sign: Metal.Expression.Binary, _ out: inout [Metal.Statement]) throws(Error) {
        let second = try pop(width.value)
        let first = try pop(width.value)
        let worked = Metal.Expression.binary(Self.unsigned(first, width.unsigned), sign, Self.unsigned(second, width.unsigned))
        try make(width.value, .convert(width.signed, [worked]), &out)
    }

    /// An expression as a type: a constant as that type's, and one that has the type as it stands.
    private static func unsigned(_ expression: Metal.Expression, _ kind: Metal.Kind) -> Metal.Expression {
        switch (kind, expression) {
        case (.uint, .convert(.int, let values)), (.ulong, .convert(.long, let values)):
            switch values.first {
            case .uint(let bits)? where values.count == 1 && kind == .uint: .uint(bits)
            case .ulong(let bits)? where values.count == 1 && kind == .ulong: .ulong(bits)
            default: .convert(kind, [expression])
            }
        case (.int, _), (.long, _), (.float, _): expression
        default: .convert(kind, [expression])
        }
    }

    /// A shift's count within the width.
    private static func count(_ expression: Metal.Expression, _ mask: UInt32) -> Metal.Expression {
        guard case .convert(_, let values) = expression, values.count == 1 else {
            return .binary(.convert(.uint, [expression]), .and, .uint(mask))
        }
        switch values[0] {
        case .uint(let bits): return .uint(bits & mask)
        case .ulong(let bits): return .uint(UInt32(truncatingIfNeeded: bits) & mask)
        default: return .binary(.convert(.uint, [expression]), .and, .uint(mask))
        }
    }

    private mutating func signed(_ width: Width, _ sign: Metal.Expression.Binary, _ out: inout [Metal.Statement]) throws(Error) {
        let second = try pop(width.value)
        try make(width.value, .binary(try pop(width.value), sign, second), &out)
    }

    private mutating func compare(
        _ value: Value,
        as kind: Metal.Kind,
        _ sign: Metal.Expression.Binary,
        _ out: inout [Metal.Statement]
    ) throws(Error) {
        let second = try pop(value)
        let first = try pop(value)
        let compared = Metal.Expression.binary(Self.unsigned(first, kind), sign, Self.unsigned(second, kind))
        try make(.i32, .convert(.int, [compared]), &out)
    }

    private mutating func shift(_ width: Width, _ sign: Metal.Expression.Binary, as kind: Metal.Kind, _ out: inout [Metal.Statement]) throws(Error) {
        let count = Self.count(try pop(width.value), width.mask)
        let value = try pop(width.value)
        try make(width.value, .convert(width.signed, [.binary(.convert(kind, [value]), sign, count)]), &out)
    }

    private mutating func rotate(_ width: Width, right: Bool, _ out: inout [Metal.Statement]) throws(Error) {
        let count = Metal.Expression.convert(width.unsigned, [try pop(width.value)])
        let value = Metal.Expression.convert(width.unsigned, [try pop(width.value)])
        let turned = Metal.Expression.call("rotate", [value, right ? .unary(.minus, count) : count])
        try make(width.value, .convert(width.signed, [turned]), &out)
    }

    private mutating func unary(
        _ from: Value,
        _ to: Value,
        _ out: inout [Metal.Statement],
        _ worked: (Metal.Expression) -> Metal.Expression
    ) throws(Error) {
        try make(to, worked(try pop(from)), &out)
    }

    private mutating func floating(_ out: inout [Metal.Statement], _ worked: (Metal.Expression, Metal.Expression) -> Metal.Expression) throws(Error) {
        let second = try pop(.f32)
        try make(.f32, worked(try pop(.f32), second), &out)
    }

    mutating func numeric(_ numeric: Instruction.Numeric, _ out: inout [Metal.Statement]) throws(Error) {
        switch numeric {
        case .i32Eqz, .i32Eq, .i32Ne, .i32LtS, .i32LtU, .i32GtS, .i32GtU, .i32LeS, .i32LeU, .i32GeS, .i32GeU,
            .i64Eqz, .i64Eq, .i64Ne, .i64LtS, .i64LtU, .i64GtS, .i64GtU, .i64LeS, .i64LeU, .i64GeS, .i64GeU,
            .f32Eq, .f32Ne, .f32Lt, .f32Gt, .f32Le, .f32Ge:
            try comparison(numeric, &out)
        case .i32Clz, .i32Ctz, .i32Popcnt, .i32Add, .i32Sub, .i32Mul, .i32DivS, .i32DivU, .i32RemS, .i32RemU, .i32And, .i32Or, .i32Xor,
            .i32Shl, .i32ShrS, .i32ShrU, .i32Rotl, .i32Rotr:
            try arithmetic(numeric.rawValue - Instruction.Numeric.i32Clz.rawValue, .narrow, &out)
        case .i64Clz, .i64Ctz, .i64Popcnt, .i64Add, .i64Sub, .i64Mul, .i64DivS, .i64DivU, .i64RemS, .i64RemU, .i64And, .i64Or, .i64Xor,
            .i64Shl, .i64ShrS, .i64ShrU, .i64Rotl, .i64Rotr:
            try arithmetic(numeric.rawValue - Instruction.Numeric.i64Clz.rawValue, .wide, &out)
        case .f32Abs: try unary(.f32, .f32, &out) { .bits(.float, .binary(.bits(.uint, $0), .and, .uint(0x7FFF_FFFF))) }
        case .f32Neg: try unary(.f32, .f32, &out) { .bits(.float, .binary(.bits(.uint, $0), .xor, .uint(0x8000_0000))) }
        case .f32Ceil: try unary(.f32, .f32, &out) { .call("ceil", [$0]) }
        case .f32Floor: try unary(.f32, .f32, &out) { .call("floor", [$0]) }
        case .f32Trunc: try unary(.f32, .f32, &out) { .call("trunc", [$0]) }
        case .f32Nearest: try unary(.f32, .f32, &out) { .call("rint", [$0]) }
        case .f32Sqrt: try unary(.f32, .f32, &out) { .call("precise::sqrt", [$0]) }
        case .f32Add: try floating(&out) { .binary($0, .plus, $1) }
        case .f32Sub: try floating(&out) { .binary($0, .minus, $1) }
        case .f32Mul: try floating(&out) { .binary($0, .times, $1) }
        case .f32Div: try floating(&out) { .call("precise::divide", [$0, $1]) }
        case .f32Min:
            use.helpers.insert(.least)
            try floating(&out) { .call(Helper.least.rawValue, [$0, $1]) }
        case .f32Max:
            use.helpers.insert(.most)
            try floating(&out) { .call(Helper.most.rawValue, [$0, $1]) }
        case .f32Copysign: try floating(&out) { .call("copysign", [$0, $1]) }
        default: try conversion(numeric, &out)
        }
    }

    private mutating func comparison(_ numeric: Instruction.Numeric, _ out: inout [Metal.Statement]) throws(Error) {
        let signs: [Metal.Expression.Binary] = [.equal, .unequal, .less, .less, .greater, .greater, .atMost, .atMost, .atLeast, .atLeast]
        switch numeric {
        case .i32Eqz: try unary(.i32, .i32, &out) { .convert(.int, [.binary($0, .equal, .uint(0))]) }
        case .i64Eqz: try unary(.i64, .i32, &out) { .convert(.int, [.binary($0, .equal, .ulong(0))]) }
        default:
            let byte = numeric.rawValue
            if byte >= Instruction.Numeric.f32Eq.rawValue {
                let floats: [Metal.Expression.Binary] = [.equal, .unequal, .less, .greater, .atMost, .atLeast]
                try compare(.f32, as: .float, floats[Int(byte - Instruction.Numeric.f32Eq.rawValue)], &out)
            } else {
                let wide = byte > Instruction.Numeric.i64Eqz.rawValue
                let place = Int(byte - (wide ? Instruction.Numeric.i64Eq.rawValue : Instruction.Numeric.i32Eq.rawValue))
                let width = wide ? Width.wide : .narrow
                let unsigned = place > 2 && place % 2 == 1
                try compare(width.value, as: unsigned ? width.unsigned : width.signed, signs[place], &out)
            }
        }
    }

    private mutating func arithmetic(_ place: UInt8, _ width: Width, _ out: inout [Metal.Statement]) throws(Error) {
        func counted(_ name: String) -> (Metal.Expression) -> Metal.Expression {
            { .convert(width.signed, [.call(name, [.convert(width.unsigned, [$0])])]) }
        }
        switch place {
        case 0: try unary(width.value, width.value, &out, counted("clz"))
        case 1: try unary(width.value, width.value, &out, counted("ctz"))
        case 2: try unary(width.value, width.value, &out, counted("popcount"))
        case 3: try integer(width, .plus, &out)
        case 4: try integer(width, .minus, &out)
        case 5: try integer(width, .times, &out)
        case 6: try signed(width, .over, &out)
        case 7: try integer(width, .over, &out)
        case 8: try signed(width, .remainder, &out)
        case 9: try integer(width, .remainder, &out)
        case 10: try integer(width, .and, &out)
        case 11: try integer(width, .or, &out)
        case 12: try integer(width, .xor, &out)
        case 13: try shift(width, .left, as: width.unsigned, &out)
        case 14: try shift(width, .right, as: width.signed, &out)
        case 15: try shift(width, .right, as: width.unsigned, &out)
        case 16: try rotate(width, right: false, &out)
        default: try rotate(width, right: true, &out)
        }
    }

    private mutating func conversion(_ numeric: Instruction.Numeric, _ out: inout [Metal.Statement]) throws(Error) {
        func through(_ kinds: Metal.Kind...) -> (Metal.Expression) -> Metal.Expression {
            { kinds.reduce($0) { .convert($1, [$0]) } }
        }
        switch numeric {
        case .i32WrapI64: try unary(.i64, .i32, &out, through(.ulong, .uint, .int))
        case .i32TruncF32S: try unary(.f32, .i32, &out, through(.int))
        case .i32TruncF32U: try unary(.f32, .i32, &out, through(.uint, .int))
        case .i64ExtendI32S: try unary(.i32, .i64, &out, through(.long))
        case .i64ExtendI32U: try unary(.i32, .i64, &out, through(.uint, .ulong, .long))
        case .i64TruncF32S: try unary(.f32, .i64, &out, through(.long))
        case .i64TruncF32U: try unary(.f32, .i64, &out, through(.ulong, .long))
        case .f32ConvertI32S: try unary(.i32, .f32, &out, through(.float))
        case .f32ConvertI32U: try unary(.i32, .f32, &out, through(.uint, .float))
        case .f32ConvertI64S: try unary(.i64, .f32, &out, through(.float))
        case .f32ConvertI64U: try unary(.i64, .f32, &out, through(.ulong, .float))
        case .i32ReinterpretF32: try unary(.f32, .i32, &out) { .bits(.int, $0) }
        case .f32ReinterpretI32: try unary(.i32, .f32, &out) { .bits(.float, $0) }
        case .i32Extend8S: try unary(.i32, .i32, &out, through(.scalar(.char), .int))
        case .i32Extend16S: try unary(.i32, .i32, &out, through(.scalar(.short), .int))
        case .i64Extend8S: try unary(.i64, .i64, &out, through(.scalar(.char), .long))
        case .i64Extend16S: try unary(.i64, .i64, &out, through(.scalar(.short), .long))
        case .i64Extend32S: try unary(.i64, .i64, &out, through(.int, .long))
        default: throw .value(.f64, function: index)
        }
    }
}
