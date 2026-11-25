internal import Metal_Standard
internal import Shader

extension Shader.Compiler {
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

        static func < (first: Self, second: Self) -> Bool { first.rawValue < second.rawValue }
    }
}

extension Shader.Compiler.Helper {
    static let loading: Set<Self> = [.load, .loadByte, .storeByte]

    /// The helpers wanted and those they call, each after what it calls.
    static func needed(by wanted: Set<Self>) -> [Self] {
        var all = wanted
        if all.contains(.loadByte) || all.contains(.storeByte) { all.insert(.load) }
        if all.contains(.storeByte) { all.insert(.store) }
        return allCases.filter(all.contains).sorted()
    }

    func function(_ memory: Shader.Compiler.Memory) -> Metal.Function {
        let state = Metal.Function.Parameter(Shader.Compiler.Unit.stateKind, "s")
        let address = Metal.Function.Parameter(.uint, "at")
        let at = Metal.Expression.name("at")
        let value = Metal.Expression.name("value")
        let s = Shader.Compiler.Unit.state
        func inner(_ result: Metal.Kind, _ parameters: [Metal.Function.Parameter], _ body: [Metal.Statement]) -> Metal.Function {
            .init(role: .inline, result: result, name: rawValue, parameters: parameters, body: body)
        }
        /// Where an address lies in an array of words that begins at another.
        func place(_ start: Int32) -> Metal.Expression {
            .binary(.binary(at, .minus, .uint(UInt32(bitPattern: start))), .right, .uint(2))
        }
        let stack = Metal.Expression.element(.member(s, "memory"), place(memory.bottom))
        let inside = Metal.Expression.binary(.binary(at, .minus, .uint(UInt32(bitPattern: memory.bottom))), .less, .uint(UInt32(memory.size)))
        let shift = Metal.Expression.binary(.binary(at, .and, .uint(3)), .left, .uint(3))
        let word = Metal.Expression.binary(at, .and, .uint(~3))
        switch self {
        case .loadStack: return inner(.uint, [state, address], [.return(stack)])
        case .storeStack: return inner(.void, [state, address, .init(.uint, "value")], [.assign(stack, value)])
        case .load:
            var body: [Metal.Statement] = []
            if memory.size > 0 { body.append(.if(inside, [.return(stack)])) }
            if memory.image.words.isEmpty {
                body.append(.return(.uint(0)))
            } else {
                let inImage = Metal.Expression.binary(place(memory.image.start), .less, .uint(UInt32(memory.image.words.count)))
                body.append(.return(.conditional(inImage, .element(.name(Shader.Compiler.Image.name), place(memory.image.start)), .uint(0))))
            }
            return inner(.uint, [state, address], body)
        case .loadByte:
            let loaded = Metal.Expression.call(Self.load.rawValue, [s, word])
            return inner(.uint, [state, address], [.return(.binary(.binary(loaded, .right, shift), .and, .uint(255)))])
        case .store:
            let body: [Metal.Statement] = memory.size > 0 ? [.if(inside, [.assign(stack, value)])] : []
            return inner(.void, [state, address, .init(.uint, "value")], body)
        case .storeByte:
            let loaded = Metal.Expression.call(Self.load.rawValue, [s, word])
            let cleared = Metal.Expression.binary(loaded, .and, .unary(.complement, .binary(.uint(255), .left, shift)))
            let put = Metal.Expression.binary(cleared, .or, .binary(.binary(value, .and, .uint(255)), .left, shift))
            return inner(.void, [state, address, .init(.uint, "value")], [.evaluate(.call(Self.store.rawValue, [s, word, put]))])
        case .least, .most:
            let first = Metal.Expression.name("first")
            let second = Metal.Expression.name("second")
            let nan = Metal.Expression.binary(.call("isnan", [first]), .either, .call("isnan", [second]))
            let same = Metal.Expression.binary(first, .equal, second)
            let bits = Metal.Expression.bits(
                .float,
                .binary(.bits(.uint, first), self == .least ? .or : .and, .bits(.uint, second))
            )
            let chosen = Metal.Expression.conditional(.binary(first, self == .least ? .less : .greater, second), first, second)
            return inner(
                .float,
                [.init(.float, "first"), .init(.float, "second")],
                [.if(nan, [.return(.float(0x7FC0_0000))]), .if(same, [.return(bits)]), .return(chosen)]
            )
        }
    }
}
