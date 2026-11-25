internal import Shader

extension Shader.Compiler {
    /// What a function uses beyond its values.
    struct Use {
        var reads: Set<Int32> = []
        var writes: Set<Int32> = []
        /// The buffers read at places known beforehand, and those of them that a kernel only so reads.
        var fixed: Set<Int32> = []
        var constants: Set<Int32> = []
        var results: Set<Int32> = []
        /// Whether a kernel's lanes are told apart, and whether a texture is written.
        var lanes = false
        var surface = false
        var calls: Set<Key> = []
        /// The helpers the function calls.
        var helpers: Set<Helper> = []

        mutating func formUnion(_ other: Self) {
            reads.formUnion(other.reads)
            writes.formUnion(other.writes)
            fixed.formUnion(other.fixed)
            constants.formUnion(other.constants)
            results.formUnion(other.results)
            lanes = lanes || other.lanes
            surface = surface || other.surface
            helpers.formUnion(other.helpers)
        }
    }
}

extension Shader.Compiler {
    /// What is done with the memory a parameter numbers.
    struct Access: Hashable {
        var written = false
    }
}

extension Shader.Compiler {
    /// A function, and the buffers it reads from memory that only holds constants.
    struct Key: Hashable, Comparable {
        var index: Int
        var constants: Set<Int32> = []

        /// The function's name in the text.
        var name: String { constants.sorted().reduce(into: "shader_\(index)") { $0 += "_\($1)" } }

        static func < (first: Self, second: Self) -> Bool { first.name < second.name }
    }
}
