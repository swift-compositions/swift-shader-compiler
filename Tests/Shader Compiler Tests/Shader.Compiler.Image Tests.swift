import Byte
import Testing

@testable import Shader_Compiler

extension `Shader.Compiler Tests` {
    @Suite
    struct Image {
        /// A module of two data segments: Swift's module hash at 1024, then four bytes at 2048.
        static func module(named: Bool) -> W3C.WebAssembly.Module {
            var module = W3C.WebAssembly.Module()
            module.data = [
                .init(memory: 0, offset: [.i32(1024)], bytes: (0..<16).map { Byte(bitPattern: UInt8($0) &* 37) }),
                .init(memory: 0, offset: [.i32(2048)], bytes: [1, 2, 3, 4].map { Byte(bitPattern: $0) }),
            ]
            guard named else { return module }
            let names: [UInt8] = [2, 0, 14] + Array(".swift_modhash".utf8) + [1, 7] + Array(".rodata".utf8)
            let section: [UInt8] = [9, UInt8(names.count)] + names
            module.custom = [.init(name: "name", bytes: section.map { Byte(bitPattern: $0) })]
            return module
        }

        @Test
        func `Swift's module hashes are left out of the image, so it does not change with the paths of a build`() {
            let image = Shader.Compiler.Image(Self.module(named: true))
            #expect(image.start == 2048)
            #expect(image.words == [0x0403_0201])
        }

        @Test
        func `Without names every data segment is in the image`() {
            let image = Shader.Compiler.Image(Self.module(named: false))
            #expect(image.start == 1024)
            #expect(image.words.count == (2048 + 4 - 1024) / 4)
        }
    }
}
