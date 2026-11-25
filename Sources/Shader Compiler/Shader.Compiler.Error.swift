public import Shader
public import W3C_WebAssembly

extension Shader.Compiler {
    /// Why a module has no text.
    public enum Error: Swift.Error, Sendable, Hashable {
        /// No export is named as an entry.
        case entries
        /// An entry does not take or give what its kind does.
        case signature(entry: String)
        /// A function reaches itself.
        case recursion(function: Int)
        /// A function takes, gives or works a value the language has no type for.
        case value(W3C.WebAssembly.Value, function: Int)
        /// An instruction has no counterpart.
        case instruction(String, function: Int)
        /// A block takes values or gives more than one.
        case block(function: Int)
        /// A function from outside is not the shader's.
        case imported(module: String, name: String)
        /// A buffer's number or a result's component is not a constant.
        case constant(function: Int)
        /// The module is not well formed.
        case malformed(function: Int)
    }
}
