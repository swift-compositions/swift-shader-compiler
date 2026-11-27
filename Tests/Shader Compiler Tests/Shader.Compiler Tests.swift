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
        func `A kernel reads one buffer and writes another, each bound at its number, one read only at known places as constants`() throws {
            let body: [Instruction] = [
                .i32(3), .i32(0), .i32(1), .i32(8), .call(0), .localGet(0), .numeric(.i32Add), .call(1),
            ]
            let text = try Shader.Compiler.metal(`Shader.Compiler Tests`.module("kernel_add", `Shader.Compiler Tests`.place, body)).text
            #expect(
                text == """
                    struct Shader_State {
                        constant uint * c1;
                        device uint * w3;
                    };

                    static __attribute__((always_inline)) void shader_2_1(thread Shader_State & s, int l0, int l1) {
                        int t1 = int(s.c1[2u]);
                        int t2 = int(uint(t1) + uint(l0));
                        s.w3[0u] = uint(t2);
                    }

                    kernel void add(constant uint * b1 [[buffer(1)]], device uint * b3 [[buffer(3)]], uint2 id [[thread_position_in_grid]]) {
                        Shader_State s;
                        s.c1 = b1;
                        s.w3 = b3;
                        shader_2_1(s, int(id.x), int(id.y));
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
            #expect(contents.contains("package static let kernels = #\"\"\"\n            a\n\n                b\n"))
            #expect(Shader.Compiler.File(reading: "import Picture\n") == nil)
        }

        @Test
        func `A generated file of WGSL says so, and carries each kernel's module by name`() {
            let file = Shader.Compiler.File(language: .wgsl, target: "Picture Shader", constant: "Picture.Renderer.WebGPU.kernels")
            let contents = file.contents(["b": "two\n", "a": "one\n"])
            #expect(contents.hasPrefix("// institute shader (WGSL): Picture Shader, Picture.Renderer.WebGPU.kernels\n"))
            #expect(Shader.Compiler.File(reading: contents) == file)
            #expect(contents.contains("    package static let kernels: [Swift.String: Swift.String] = [\n        \"a\": #\"\"\"\n            one\n"))
            #expect(contents.contains("\"\"\"#,\n        \"b\": #\"\"\"\n            two\n"))
            #expect(Shader.Compiler.File(reading: "// institute shader (GLSL): Picture Shader, Picture.kernels\n") == nil)
        }
    }

    @Suite
    struct WGSL {
        @Test
        func `A kernel reads one buffer and writes another in the heap, each at the place its number is given`() throws {
            let body: [Instruction] = [
                .i32(3), .i32(0), .i32(1), .i32(8), .call(0), .localGet(0), .numeric(.i32Add), .call(1),
            ]
            let texts = try Shader.Compiler.wgsl(`Shader.Compiler Tests`.module("kernel_add", `Shader.Compiler Tests`.place, body))
            #expect(
                texts["add"]?.text == """
                    struct Shader_Dispatch {
                        grid: vec4<u32>,
                        bases: array<vec4<u32>, 8>,
                    }

                    @group(0) @binding(0) var<storage, read_write> heap: array<u32>;

                    @group(0) @binding(1) var<uniform> dispatch: Shader_Dispatch;

                    fn shader_2_1(p0: i32, p1: i32) {
                        var l0: i32 = p0;
                        var l1: i32 = p1;
                        let t1 = bitcast<i32>(heap[dispatch.bases[0u].y + 2u]);
                        let t2 = bitcast<i32>(bitcast<u32>(t1) + bitcast<u32>(l0));
                        heap[dispatch.bases[0u].w + 0u] = bitcast<u32>(t2);
                    }

                    @compute @workgroup_size(64, 1, 1)
                    fn add(@builtin(global_invocation_id) id: vec3<u32>) {
                        if ((id.x >= dispatch.grid.x) || (id.y >= dispatch.grid.y)) {
                            return;
                        }
                        shader_2_1(i32(id.x), i32(id.y));
                    }

                    """
            )
        }

        @Test
        func `A block is a loop its end leaves, a branch further out says which it leaves, and a parameter is copied to change`() throws {
            let body: [Instruction] = [
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
                )
            ]
            let text = try Shader.Compiler.wgsl(`Shader.Compiler Tests`.module("kernel_down", `Shader.Compiler Tests`.place, body))["down"]?.text ?? ""
            #expect(text.contains("var l0: i32 = p0;"))
            #expect(text.contains("loop {\n        loop {"))
            #expect(text.contains("shader_target = 1u;\n                break;\n            }\n            continue;"))
            #expect(text.contains("if (shader_target != 0u) {\n            break;\n        }\n        break;\n    }"))
        }

        @Test
        func `A 64-bit integer is two words, and arithmetic on constants is worked out before the text`() throws {
            let body: [Instruction] = [
                .i32(1), .i32(0), .i64(-1), .i64(2), .numeric(.i64Add), .localGet(0), .numeric(.i64ExtendI32S), .numeric(.i64Xor),
                .numeric(.i32WrapI64), .call(1),
            ]
            let text = try Shader.Compiler.wgsl(`Shader.Compiler Tests`.module("kernel_wide", `Shader.Compiler Tests`.place, body))["wide"]?.text ?? ""
            #expect(text.contains("let t1 = shader_i64_extend_s(l0);"))
            #expect(text.contains("let t2 = vec2<u32>(vec2<u32>(1u, 0u).x ^ t1.x, vec2<u32>(1u, 0u).y ^ t1.y);"))
            #expect(text.contains("fn shader_i64_extend_s(a: i32) -> vec2<u32> {"))
        }
    }
}
