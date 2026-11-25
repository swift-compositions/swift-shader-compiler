internal import Shader

extension Shader.Compiler {
    /// What a function uses beyond its values.
    struct Use {
        var reads: Set<Int32> = []
        var writes: Set<Int32> = []
        var results: Set<Int32> = []
        var calls: Set<Int> = []
        /// The helpers the function calls.
        var helpers: Set<Helper> = []

        mutating func formUnion(_ other: Self) {
            reads.formUnion(other.reads)
            writes.formUnion(other.writes)
            results.formUnion(other.results)
            helpers.formUnion(other.helpers)
        }
    }
}
