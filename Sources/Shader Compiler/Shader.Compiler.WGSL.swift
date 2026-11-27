internal import Shader
internal import W3C_WGSL

extension Shader.Compiler {
    /// What writes a module's kernels in WGSL. A kernel there has no pointers: every buffer it is handed lies in one
    /// array of words, `heap`, at a place `bases` gives by the buffer's number, beside the size of the grid. A 64-bit
    /// integer is two words, low first; the stack, the globals and the arrays a place keeps apart are an
    /// invocation's own variables; and a kernel's lanes are one, so a sum over them is the number itself.
    enum WGSL {}
}

extension Shader.Compiler.WGSL {
    typealias Expression = W3C.WGSL.Expression
    typealias Statement = W3C.WGSL.Statement
    typealias Kind = W3C.WGSL.Kind

    /// A 64-bit integer: two words, low first.
    static let wide = Kind.vector(.u32, 2)

    /// The buffers a kernel is handed, the data the module starts with, and the texture it writes.
    static let heap = "heap"
    static let image = "image"
    static let surface = "surface"
    /// The grid and the places of the buffers, by number.
    static let dispatch = "dispatch"
    /// How many buffers a kernel may be handed.
    static let buffers = 32

    /// The place in `heap` where a buffer begins, by its number.
    static func base(_ number: Int32) -> Expression {
        let lanes = ["x", "y", "z", "w"]
        let vector = Expression.element(.member(.name(dispatch), "bases"), .u32(UInt32(number) / 4))
        return .member(vector, lanes[Int(number) % 4])
    }

    /// An `i32` as a `u32` of the same bits.
    static func unsigned(_ expression: Expression) -> Expression {
        switch expression {
        case .i32(let number): .u32(UInt32(bitPattern: number))
        case .bitcast(.i32, let inner): inner
        default: .bitcast(.u32, expression)
        }
    }

    /// A `u32` as an `i32` of the same bits.
    static func signed(_ expression: Expression) -> Expression {
        switch expression {
        case .u32(let number): .i32(Int32(bitPattern: number))
        case .bitcast(.u32, let inner): inner
        default: .bitcast(.i32, expression)
        }
    }

    /// An `i32` that is not zero, as a `bool`.
    static func truth(_ expression: Expression) -> Expression { .binary(expression, .unequal, .i32(0)) }

    /// A `bool` as an `i32`: one or zero.
    static func number(_ condition: Expression) -> Expression { .construct(.i32, [condition]) }

    /// A 64-bit constant.
    static func wide(_ number: UInt64) -> Expression {
        .construct(wide, [.u32(UInt32(truncatingIfNeeded: number)), .u32(UInt32(truncatingIfNeeded: number >> 32))])
    }

    /// The 64-bit constant an expression is, if it is one.
    static func wideNumber(_ expression: Expression) -> UInt64? {
        guard case .construct(wide, let parts) = expression, parts.count == 2, case .u32(let low) = parts[0], case .u32(let high) = parts[1]
        else { return nil }
        return UInt64(high) << 32 | UInt64(low)
    }

    /// An `f32` constant: a literal, or for a NaN or an infinity, which have none, its bits read at run time.
    static func float(_ bits: UInt32, _ helpers: inout Set<Helper>) -> Expression {
        guard (bits >> 23) & 0xFF == 0xFF else { return .f32(bits) }
        helpers.insert(.float)
        return .call(Helper.float.rawValue, [.u32(bits)])
    }
}
