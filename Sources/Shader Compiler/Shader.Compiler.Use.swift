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
        /// The arrays a place keeps apart, by number, and how many words each has.
        var locals: [Int32: Int32] = [:]
        var surface = false
        /// The textures read or sampled, and those written, by number; whether any is sampled, and whether what
        /// was read last is asked for.
        var textures: Set<Int32> = []
        var stores: Set<Int32> = []
        var samples = false
        var texel = false
        /// Whether a corner's position is given, and the places a vertex stage hands vectors on at and a fragment
        /// stage takes them at, each with whether its vector is of whole numbers and so not interpolated.
        var position = false
        var handed: [Int32: Bool] = [:]
        var taken: [Int32: Bool] = [:]
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
            locals.merge(other.locals, uniquingKeysWith: max)
            surface = surface || other.surface
            textures.formUnion(other.textures)
            stores.formUnion(other.stores)
            samples = samples || other.samples
            texel = texel || other.texel
            position = position || other.position
            handed.merge(other.handed) { first, _ in first }
            taken.merge(other.taken) { first, _ in first }
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
