public import Metal_Standard
public import Shader
public import W3C_WebAssembly

extension Shader {
    /// Writes a module of kernels in a GPU's language.
    public enum Compiler {}
}

extension Shader.Compiler {
    /// The module's entries in Metal's shading language, with every function they reach.
    public static func metal(_ module: W3C.WebAssembly.Module) throws(Error) -> Metal.Source {
        var unit = Unit(module: module, entries: try Entry.entries(of: module))
        return try unit.source()
    }
}
