internal import Binary
internal import Byte
internal import W3C_WebAssembly

extension Shader.Compiler.Image {
    /// The name of the data Swift writes into every object it compiles: a hash of the object's LLVM module, taken over
    /// the paths of its build. No kernel reads it, and in the image it would make the kernels differ from one checkout
    /// of the same source to another.
    static let hash = ".swift_modhash"

    /// The indices of the module's data segments named `name`, from the data segment names of its name section
    /// (subsection 9 of WebAssembly's extended name section); none when the module keeps no names.
    static func segments(named name: String, in module: W3C.WebAssembly.Module) -> Set<Int> {
        var found: Set<Int> = []
        for section in module.custom where section.name == "name" {
            var rest = section.bytes[...]
            while let id = rest.popFirst() {
                guard let size = number(&rest), rest.count >= size else { break }
                var names = rest.prefix(size)
                rest = rest.dropFirst(size)
                guard id.bitPattern == 9, let count = number(&names) else { continue }
                for _ in 0..<count {
                    guard let index = number(&names), let length = number(&names), names.count >= length else { break }
                    if String(decoding: names.prefix(length).map(\.bitPattern), as: UTF8.self) == name { found.insert(index) }
                    names = names.dropFirst(length)
                }
            }
        }
        return found
    }

    /// An unsigned number of WebAssembly's encoding, or nil where the bytes hold none.
    private static func number(_ bytes: inout ArraySlice<Byte>) -> Int? {
        do throws(Binary.LEB128.Error) {
            return Int(try Binary.LEB128.Unsigned<UInt32>().parse(&bytes))
        } catch {
            return nil
        }
    }
}
