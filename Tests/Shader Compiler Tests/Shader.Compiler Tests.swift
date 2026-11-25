import Shader_Compiler
import Testing

enum `Shader.Compiler Tests` {}

extension `Shader.Compiler Tests` {
    typealias Module = W3C.WebAssembly.Module
    typealias Instruction = W3C.WebAssembly.Instruction

    /// A module of one exported function, over the shader's load and store.
    static func module(
        _ name: String,
        _ signature: W3C.WebAssembly.Signature,
        _ body: [Instruction],
        imports: [W3C.WebAssembly.Import] = [
            .init(module: "shader", name: "load", kind: .function(1)), .init(module: "shader", name: "store", kind: .function(2)),
        ]
    ) -> Module {
        var module = Module()
        module.types = [
            signature, .init(parameters: [.i32, .i32], results: [.i32]), .init(parameters: [.i32, .i32, .i32], results: []),
        ]
        module.imports = imports
        module.functions = [.init(type: 0, locals: [], body: body)]
        module.exports = [.init(name: name, kind: .function, index: imports.count)]
        return module
    }

    static let place = W3C.WebAssembly.Signature(parameters: [.i32, .i32], results: [])

    @Suite
    struct Metal {
        @Test
        func `A kernel reads one buffer and writes another, each bound at its number`() throws {
            let body: [Instruction] = [
                .i32(3), .i32(0), .i32(1), .i32(8), .call(0), .localGet(0), .numeric(.i32Add), .call(1),
            ]
            let text = try Shader.Compiler.metal(`Shader.Compiler Tests`.module("kernel_add", `Shader.Compiler Tests`.place, body)).text
            #expect(
                text == """
                    struct Shader_State {
                        device const uint * r1;
                        device uint * w3;
                    };

                    static void shader_2(thread Shader_State & s, int l0, int l1) {
                        #pragma METAL fp math_mode(safe)
                        #pragma METAL fp contract(off)
                        int t1 = int(s.r1[2u]);
                        int t2 = int(uint(t1) + uint(l0));
                        s.w3[0u] = uint(t2);
                    }

                    kernel void add(device const uint * b1 [[buffer(1)]], device uint * b3 [[buffer(3)]], uint2 id [[thread_position_in_grid]]) {
                        Shader_State s;
                        s.r1 = b1;
                        s.w3 = b3;
                        shader_2(s, int(id.x), int(id.y));
                    }

                    """
            )
        }

        @Test
        func `A branch out of a loop and a block says which it leaves, and a local is kept before it changes`() throws {
            let body: [Instruction] = [
                .localGet(0),
                .block(
                    .empty,
                    [
                        .loop(
                            .empty,
                            [
                                .localGet(0), .i32(1), .numeric(.i32Sub), .localTee(0), .numeric(.i32Eqz), .brIf(1), .br(0),
                            ]
                        )
                    ]
                ),
            ]
            let signature = W3C.WebAssembly.Signature(parameters: [.i32], results: [.i32])
            let text = try Shader.Compiler.metal(`Shader.Compiler Tests`.module("function_down", signature, body)).text
            #expect(text.contains("int t1 = l0;\n    do {\n        while (true) {"))
            #expect(text.contains("if (t3 != 0u) {\n                target = 1u;\n                break;\n            }\n            continue;"))
            #expect(text.contains("return t1;"))
        }

        @Test
        func `What cannot be written exactly is refused by name`() {
            let none = W3C.WebAssembly.Signature(parameters: [], results: [])
            #expect(throws: Shader.Compiler.Error.entries) { try Shader.Compiler.metal(`Shader.Compiler Tests`.module("other", none, [])) }
            #expect(throws: Shader.Compiler.Error.recursion(function: 2)) {
                try Shader.Compiler.metal(`Shader.Compiler Tests`.module("function_again", none, [.call(2)]))
            }
            #expect(throws: Shader.Compiler.Error.value(.f64, function: 2)) {
                try Shader.Compiler.metal(`Shader.Compiler Tests`.module("function_wide", none, [.f64(0), .drop]))
            }
            #expect(throws: Shader.Compiler.Error.constant(function: 2)) {
                try Shader.Compiler.metal(`Shader.Compiler Tests`.module("kernel_any", `Shader.Compiler Tests`.place, [.localGet(0), .i32(0), .call(0), .drop]))
            }
            #expect(throws: Shader.Compiler.Error.imported(module: "env", name: "pow")) {
                try Shader.Compiler.metal(
                    `Shader.Compiler Tests`.module("kernel_pow", `Shader.Compiler Tests`.place, [.i32(0), .i32(0), .call(0), .drop], imports: [.init(module: "env", name: "pow", kind: .function(1))])
                )
            }
        }
    }

    @Suite
    struct File {
        @Test
        func `A generated file says what it is made from`() {
            let file = Shader.Compiler.File(target: "Picture Shader", constant: "Picture.Renderer.kernels", condition: "Metal && canImport(Metal)")
            let contents = file.contents("a\n\n    b\n")
            #expect(Shader.Compiler.File(reading: contents) == file)
            #expect(contents.contains("extension Picture.Renderer {"))
            #expect(contents.contains("static let kernels = #\"\"\"\n            a\n\n                b\n"))
            #expect(Shader.Compiler.File(reading: "import Picture\n") == nil)
        }
    }
}
