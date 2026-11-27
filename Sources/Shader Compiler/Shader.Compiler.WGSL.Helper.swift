internal import Shader
internal import W3C_WGSL

extension Shader.Compiler.WGSL {
    /// A function of the text's own that others are written with.
    enum Helper: String, CaseIterable, Comparable {
        case load = "shader_load"
        case loadStack = "shader_load_stack"
        case storeStack = "shader_store_stack"
        case loadByte = "shader_load_byte"
        case store = "shader_store"
        case storeByte = "shader_store_byte"
        case least = "shader_min"
        case most = "shader_max"
        /// An `f32` of bits, read at run time: a NaN or an infinity, which have no literal.
        case float = "shader_f32"
        /// A number as it is, read at run time, so that an operation on constants is not worked out when the text
        /// is compiled, where one that overflows is an error.
        case keep = "shader_keep"
        case keepFloat = "shader_keep_f32"
        case round = "shader_round"
        case add = "shader_i64_add"
        case subtract = "shader_i64_sub"
        case multiply = "shader_i64_mul"
        case left = "shader_i64_shl"
        case right = "shader_i64_shr_u"
        case rightSigned = "shader_i64_shr_s"
        case less = "shader_i64_lt_u"
        case lessSigned = "shader_i64_lt_s"
        case extend = "shader_i64_extend_s"
        case truncate = "shader_i64_trunc_f32_s"
        case truncateUnsigned = "shader_i64_trunc_f32_u"
        case convert = "shader_f32_convert_i64_s"
        case convertUnsigned = "shader_f32_convert_i64_u"
        case leading = "shader_i64_clz"
        case trailing = "shader_i64_ctz"

        static func < (first: Self, second: Self) -> Bool { first.rawValue < second.rawValue }
    }
}

extension Shader.Compiler.WGSL.Helper {
    typealias WGSL = Shader.Compiler.WGSL
    typealias Expression = W3C.WGSL.Expression
    typealias Statement = W3C.WGSL.Statement

    static let loading: Set<Self> = [.load, .loadByte, .storeByte]

    /// The helpers wanted and those they call, each after what it calls.
    static func needed(by wanted: Set<Self>) -> [Self] {
        var all = wanted
        if all.contains(.loadByte) || all.contains(.storeByte) { all.insert(.load) }
        if all.contains(.storeByte) { all.insert(.store) }
        if all.contains(.subtract) || all.contains(.convert) || all.contains(.truncate) { all.insert(.subtract) }
        if all.contains(.convert) { all.insert(.convertUnsigned) }
        if all.contains(.truncate) { all.insert(.truncateUnsigned) }
        let first: [Self] = [.subtract, .convertUnsigned, .truncateUnsigned, .load, .store]
        return first.filter(all.contains) + allCases.filter { all.contains($0) && !first.contains($0) }.sorted()
    }

    func function(_ memory: Shader.Compiler.Memory) -> W3C.WGSL.Function {
        let wide = WGSL.wide
        let a = Expression.name("a")
        let b = Expression.name("b")
        let at = Expression.name("at")
        let value = Expression.name("value")
        func inner(_ result: W3C.WGSL.Kind?, _ parameters: [W3C.WGSL.Function.Parameter], _ body: [Statement]) -> W3C.WGSL.Function {
            .init(result: result, name: rawValue, parameters: parameters, body: body)
        }
        func call(_ helper: Self, _ arguments: Expression...) -> Expression { .call(helper.rawValue, arguments) }
        func low(_ e: Expression) -> Expression { .member(e, "x") }
        func high(_ e: Expression) -> Expression { .member(e, "y") }
        func pair(_ low: Expression, _ high: Expression) -> Expression { .construct(wide, [low, high]) }
        func choose(_ no: Expression, _ yes: Expression, _ condition: Expression) -> Expression { .call("select", [no, yes, condition]) }
        /// Where an address lies in an array of words that begins at another.
        func place(_ start: Int32) -> Expression {
            .binary(.binary(at, .minus, .u32(UInt32(bitPattern: start))), .right, .u32(2))
        }
        let stack = Expression.element(.name("shader_memory"), place(memory.bottom))
        let inside = Expression.binary(.binary(at, .minus, .u32(UInt32(bitPattern: memory.bottom))), .less, .u32(UInt32(memory.size)))
        let shift = Expression.binary(.binary(at, .and, .u32(3)), .left, .u32(3))
        let word = Expression.binary(at, .and, .u32(~3))
        let count = Expression.name("count")
        let s = Expression.binary(count, .and, .u32(63))
        let address = W3C.WGSL.Function.Parameter(.u32, "at")
        switch self {
        case .loadStack: return inner(.u32, [address], [.return(stack)])
        case .storeStack: return inner(nil, [address, .init(.u32, "value")], [.assign(stack, value)])
        case .load:
            var body: [Statement] = []
            if memory.size > 0 { body.append(.if(inside, [.return(stack)])) }
            if memory.image.words.isEmpty {
                body.append(.return(.u32(0)))
            } else {
                let inImage = Expression.binary(place(memory.image.start), .less, .u32(UInt32(memory.image.words.count)))
                body.append(.if(inImage, [.return(.element(.name(WGSL.image), place(memory.image.start)))]))
                body.append(.return(.u32(0)))
            }
            return inner(.u32, [address], body)
        case .loadByte:
            let loaded = Expression.call(Self.load.rawValue, [word])
            return inner(.u32, [address], [.return(.binary(.binary(loaded, .right, shift), .and, .u32(255)))])
        case .store:
            let body: [Statement] = memory.size > 0 ? [.if(inside, [.assign(stack, value)])] : []
            return inner(nil, [address, .init(.u32, "value")], body)
        case .storeByte:
            let loaded = Expression.call(Self.load.rawValue, [word])
            let cleared = Expression.binary(loaded, .and, .unary(.complement, .binary(.u32(255), .left, shift)))
            let put = Expression.binary(cleared, .or, .binary(.binary(value, .and, .u32(255)), .left, shift))
            return inner(nil, [address, .init(.u32, "value")], [.call(Self.store.rawValue, [word, put])])
        case .least, .most:
            let isNaN = { (x: Expression) -> Expression in
                .binary(.binary(.bitcast(.u32, x), .and, .u32(0x7FFF_FFFF)), .greater, .u32(0x7F80_0000))
            }
            let same = Expression.binary(a, .equal, b)
            let bits = Expression.bitcast(.f32, .binary(.bitcast(.u32, a), self == .least ? .or : .and, .bitcast(.u32, b)))
            let chosen = choose(b, a, .binary(a, self == .least ? .less : .greater, b))
            return inner(
                .f32,
                [.init(.f32, "a"), .init(.f32, "b")],
                [
                    .if(.binary(isNaN(a), .either, isNaN(b)), [.return(.call(Self.float.rawValue, [.u32(0x7FC0_0000)]))]),
                    .if(same, [.return(bits)]), .return(chosen),
                ]
            )
        case .float: return inner(.f32, [.init(.u32, "bits")], [.return(.bitcast(.f32, .name("bits")))])
        case .keep: return inner(.i32, [.init(.i32, "a")], [.return(a)])
        case .keepFloat: return inner(.f32, [.init(.f32, "a")], [.return(a)])
        case .round:
            // Halves away from zero, as C's roundf.
            let whole = Expression.call("trunc", [a])
            return inner(
                .f32,
                [.init(.f32, "a")],
                [
                    .let("whole", whole),
                    .return(choose(.name("whole"), .binary(.name("whole"), .plus, .call("sign", [a])), .binary(.call("abs", [.binary(a, .minus, .name("whole"))]), .atLeast, .f32(0x3F00_0000)))),
                ]
            )
        case .add:
            return inner(
                wide,
                [.init(wide, "a"), .init(wide, "b")],
                [
                    .let("low", .binary(low(a), .plus, low(b))),
                    .return(pair(.name("low"), .binary(.binary(high(a), .plus, high(b)), .plus, choose(.u32(0), .u32(1), .binary(.name("low"), .less, low(a)))))),
                ]
            )
        case .subtract:
            return inner(
                wide,
                [.init(wide, "a"), .init(wide, "b")],
                [
                    .return(
                        pair(
                            .binary(low(a), .minus, low(b)),
                            .binary(.binary(high(a), .minus, high(b)), .minus, choose(.u32(0), .u32(1), .binary(low(a), .less, low(b))))
                        )
                    )
                ]
            )
        case .multiply:
            func half(_ e: Expression, _ upper: Bool) -> Expression { upper ? .binary(e, .right, .u32(16)) : .binary(e, .and, .u32(0xFFFF)) }
            let p00 = Expression.binary(half(low(a), false), .times, half(low(b), false))
            let p01 = Expression.binary(half(low(a), false), .times, half(low(b), true))
            let p10 = Expression.binary(half(low(a), true), .times, half(low(b), false))
            let p11 = Expression.binary(half(low(a), true), .times, half(low(b), true))
            let middle = Expression.binary(.binary(.binary(.name("p00"), .right, .u32(16)), .plus, half(.name("p01"), false)), .plus, half(.name("p10"), false))
            let top = Expression.binary(
                .binary(.binary(.name("p11"), .plus, half(.name("p01"), true)), .plus, half(.name("p10"), true)),
                .plus,
                half(.name("middle"), true)
            )
            let cross = Expression.binary(.binary(low(a), .times, high(b)), .plus, .binary(high(a), .times, low(b)))
            return inner(
                wide,
                [.init(wide, "a"), .init(wide, "b")],
                [
                    .let("p00", p00), .let("p01", p01), .let("p10", p10), .let("p11", p11), .let("middle", middle),
                    .return(pair(.binary(half(.name("p00"), false), .or, .binary(.name("middle"), .left, .u32(16))), .binary(top, .plus, cross))),
                ]
            )
        case .left:
            return inner(
                wide,
                [.init(wide, "a"), .init(.u32, "count")],
                [
                    .let("s", s), .if(.binary(.name("s"), .equal, .u32(0)), [.return(a)]),
                    .if(
                        .binary(.name("s"), .less, .u32(32)),
                        [.return(pair(.binary(low(a), .left, .name("s")), .binary(.binary(high(a), .left, .name("s")), .or, .binary(low(a), .right, .binary(.u32(32), .minus, .name("s"))))))]
                    ),
                    .return(pair(.u32(0), .binary(low(a), .left, .binary(.name("s"), .minus, .u32(32))))),
                ]
            )
        case .right, .rightSigned:
            let signed = self == .rightSigned
            let top: (Expression) -> Expression = { by in
                signed ? .bitcast(.u32, .binary(.bitcast(.i32, high(a)), .right, by)) : .binary(high(a), .right, by)
            }
            return inner(
                wide,
                [.init(wide, "a"), .init(.u32, "count")],
                [
                    .let("s", s), .if(.binary(.name("s"), .equal, .u32(0)), [.return(a)]),
                    .if(
                        .binary(.name("s"), .less, .u32(32)),
                        [.return(pair(.binary(.binary(low(a), .right, .name("s")), .or, .binary(high(a), .left, .binary(.u32(32), .minus, .name("s")))), top(.name("s"))))]
                    ),
                    .return(pair(top(.binary(.name("s"), .minus, .u32(32))), signed ? top(.u32(31)) : .u32(0))),
                ]
            )
        case .less, .lessSigned:
            let first = self == .lessSigned ? Expression.bitcast(.i32, high(a)) : high(a)
            let second = self == .lessSigned ? Expression.bitcast(.i32, high(b)) : high(b)
            return inner(
                .bool,
                [.init(wide, "a"), .init(wide, "b")],
                [.return(.binary(.binary(first, .less, second), .either, .binary(.binary(first, .equal, second), .both, .binary(low(a), .less, low(b)))))]
            )
        case .extend:
            return inner(wide, [.init(.i32, "a")], [.return(pair(.bitcast(.u32, a), .bitcast(.u32, .binary(a, .right, .u32(31)))))])
        case .truncateUnsigned:
            // The integer part, held within the range, as wasm's saturating conversion: NaN gives zero.
            let whole = Expression.call("trunc", [a])
            return inner(
                wide,
                [.init(.f32, "a")],
                [
                    .if(.unary(.not, .binary(a, .greater, .f32(0))), [.return(pair(.u32(0), .u32(0)))]),
                    .if(.binary(a, .atLeast, .f32(0x5F80_0000)), [.return(pair(.u32(0xFFFF_FFFF), .u32(0xFFFF_FFFF)))]),
                    .let("whole", whole), .let("top", .call("floor", [.binary(.name("whole"), .times, .f32(0x2F80_0000))])),
                    .return(pair(.construct(.u32, [.binary(.name("whole"), .minus, .binary(.name("top"), .times, .f32(0x4F80_0000)))]), .construct(.u32, [.name("top")]))),
                ]
            )
        case .truncate:
            let magnitude = call(.truncateUnsigned, .call("abs", [a]))
            return inner(
                wide,
                [.init(.f32, "a")],
                [
                    .if(.binary(a, .atLeast, .f32(0x5F00_0000)), [.return(pair(.u32(0xFFFF_FFFF), .u32(0x7FFF_FFFF)))]),
                    .if(.binary(a, .less, .f32(0xDF00_0000)), [.return(pair(.u32(0), .u32(0x8000_0000)))]),
                    .if(.binary(a, .less, .f32(0)), [.return(call(.subtract, pair(.u32(0), .u32(0)), magnitude))]),
                    .return(magnitude),
                ]
            )
        case .convertUnsigned:
            return inner(.f32, [.init(wide, "a")], [.return(.binary(.binary(.construct(.f32, [high(a)]), .times, .f32(0x4F80_0000)), .plus, .construct(.f32, [low(a)])))])
        case .convert:
            return inner(
                .f32,
                [.init(wide, "a")],
                [
                    .if(.binary(.bitcast(.i32, high(a)), .less, .i32(0)), [.return(.unary(.minus, call(.convertUnsigned, call(.subtract, pair(.u32(0), .u32(0)), a))))]),
                    .return(call(.convertUnsigned, a)),
                ]
            )
        case .leading:
            return inner(
                wide,
                [.init(wide, "a")],
                [
                    .if(.binary(high(a), .unequal, .u32(0)), [.return(pair(.call("countLeadingZeros", [high(a)]), .u32(0)))]),
                    .return(pair(.binary(.u32(32), .plus, .call("countLeadingZeros", [low(a)])), .u32(0))),
                ]
            )
        case .trailing:
            return inner(
                wide,
                [.init(wide, "a")],
                [
                    .if(.binary(low(a), .unequal, .u32(0)), [.return(pair(.call("countTrailingZeros", [low(a)]), .u32(0)))]),
                    .return(pair(.binary(.u32(32), .plus, .call("countTrailingZeros", [high(a)])), .u32(0))),
                ]
            )
        }
    }
}
