# swift-shader-compiler

Use this package to turn kernels written with swift-shader into a GPU's language, from the WebAssembly module Swift compiles them to. Start from `Shader.Compiler.metal(_:)` for Metal's shading language, and `Shader.Compiler.File` for the generated Swift file that carries the text. It does not run the Swift compiler: the `institute shader` command does, and hands the module here.

## Laws

- The text is the module's operations in Metal's normal maths: division and square root are the GPU's own, and the compiler may fuse a multiply and an add, so a result may differ from the module's in its last bits; constants are written as bit patterns, and integer operations give the same bits. Where a GPU flushes a subnormal `float`, results may differ there too.
- What cannot be written exactly is refused with an error that names it: `Double`, recursion, a call through a pointer, a growing memory, an import that is not the shader's, a buffer whose number is not known when the code is compiled. Nothing is guessed or left out.
- Imported `__extendhfsf2` and `__truncsfhf2` are the conversions between `Float16` and `Float`, rounded to nearest even.
- A trap ends its function, whose result is then 0.
- The module's own memory is its stack, whose size is the deepest path of calls, and its data, which is read only: a store outside the stack does nothing.
- An export named `kernel_<name>` becomes a kernel of that name; its buffers are those its code reads or writes, read only where it only reads. An export named `function_<name>` becomes an inline function of that name; it gives its result, or the vector it handed to `Shader.result(_:)`.
- Every other name in the text begins with `shader_` or `Shader_`.
- Equal modules give equal text.
- A generated file's first line says what it was made from, so that it can be made again from the file alone.
