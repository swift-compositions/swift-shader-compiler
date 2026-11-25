internal import Byte
internal import Metal_Standard
internal import Shader
internal import W3C_WebAssembly

extension Shader.Compiler {
    /// The data a module starts with, as words from the first address any lies at.
    struct Image {
        var start: Int32 = 0
        var words: [UInt32] = []

        init(_ module: W3C.WebAssembly.Module) {
            var pieces: [(start: Int, bytes: [Byte])] = []
            for data in module.data {
                guard case .i32(let start)? = data.offset?.first else { continue }
                pieces.append((Int(start), data.bytes))
            }
            guard let low = pieces.map(\.start).min(), let high = pieces.map({ $0.start + $0.bytes.count }).max() else { return }
            let base = low & ~3
            var words = [UInt32](repeating: 0, count: (high - base + 3) / 4)
            for piece in pieces {
                for (place, byte) in piece.bytes.enumerated() {
                    let at = piece.start + place - base
                    words[at / 4] |= UInt32(byte.bitPattern) << (8 * (at % 4))
                }
            }
            start = Int32(base)
            self.words = words
        }
    }

    /// What stands for a module's memory: a stack that ends at `top`, and the image.
    struct Memory {
        var top: Int32
        var size: Int
        var image: Image

        var bottom: Int32 { top - Int32(size) }
    }
}

extension Shader.Compiler.Image {
    static let name = "shader_image"

    var item: Metal.Source.Item { .constants(.uint, Self.name, words.map { .uint($0) }) }
}
