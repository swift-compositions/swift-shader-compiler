public import Metal_Standard
public import Shader
public import W3C_WebAssembly
public import W3C_WGSL

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

    /// The module's kernels and stages in WGSL, each a text of its own with every function it reaches: a kernel by
    /// its name, a stage by the name it is exported under (`vertex_<name>`, `fragment_<name>`), which is also its
    /// entry point.
    ///
    /// A kernel's text binds, in group 0: at 0 `heap`, the words of every buffer it is handed; at 1 `dispatch`, a
    /// structure of the grid's columns and rows and the place in `heap` of each buffer by its number; at 2 `image`,
    /// the data the module starts with, when it reads it; and at 3 `surface`, the texture it writes, when it writes
    /// one. Its workgroups are 64 places of one row. A stage reads `heap` and does not write it. At binding 4 is
    /// `shader_sampler`, where a texture is sampled, and in group 1, at its number, each texture: `shader_texture<n>`.
    public static func wgsl(_ module: W3C.WebAssembly.Module) throws(Error) -> [String: W3C.WGSL.Source] {
        var unit = Unit(module: module, entries: try Entry.entries(of: module))
        return try unit.wgsl()
    }
}
