import Shader_Compiler
import Testing

extension `Shader.Compiler Tests` {
    /// A module of a vertex stage that gives a position and hands on two vectors, a fragment stage that samples a
    /// texture, and a kernel that reads a texture and writes another.
    static var stages: Module {
        var module = Module()
        module.types = [
            .init(parameters: [.i32, .i32], results: []),
            .init(parameters: [.f32, .f32], results: []),
            .init(parameters: [.f32, .f32, .f32, .f32], results: []),
            .init(parameters: [.i32, .f32, .f32, .f32, .f32], results: []),
            .init(parameters: [.i32, .i32, .i32, .i32, .i32], results: []),
            .init(parameters: [.i32, .f32, .f32], results: []),
            .init(parameters: [.i32], results: [.f32]),
            .init(parameters: [.i32, .i32], results: [.i32]),
            .init(parameters: [.i32, .f32], results: []),
            .init(parameters: [.i32, .i32, .i32], results: []),
            .init(parameters: [.i32, .f32, .f32, .f32, .f32, .i32, .i32], results: []),
        ]
        let names: [(String, Int)] = [
            ("position", 2), ("vary", 3), ("vary_flat", 4), ("texture_sample", 5), ("texel", 6), ("varying_flat", 7), ("result", 8),
            ("texture_load", 9), ("texture_store", 10), ("load", 7),
        ]
        module.imports = names.map { .init(module: "shader", name: $0.0, kind: .function($0.1)) }
        let one: UInt32 = 0x3F80_0000
        let corner: [Instruction] = [
            .f32(one), .f32(0), .f32(0), .f32(one), .call(0),
            .i32(0), .f32(one), .f32(0), .f32(0), .f32(0), .call(1),
            .i32(2), .localGet(1), .i32(4), .i32(8), .call(9), .i32(0), .i32(0), .call(2),
        ]
        var pixel: [Instruction] = [.i32(3), .localGet(0), .localGet(1), .call(3), .i32(2), .i32(0), .call(5), .drop]
        for component in 0..<4 { pixel += [.i32(Int32(component)), .i32(Int32(component)), .call(4), .call(6)] }
        var copy: [Instruction] = [.i32(1), .localGet(0), .localGet(1), .call(7), .i32(5)]
        for component in 0..<4 { copy += [.i32(Int32(component)), .call(4)] }
        copy += [.localGet(0), .localGet(1), .call(8)]
        module.functions = [
            .init(type: 0, locals: [], body: corner), .init(type: 1, locals: [], body: pixel), .init(type: 0, locals: [], body: copy),
        ]
        module.exports = [
            .init(name: "vertex_blit", kind: .function, index: 10), .init(name: "fragment_blit", kind: .function, index: 11),
            .init(name: "kernel_copy", kind: .function, index: 12),
        ]
        return module
    }

    @Suite
    struct Stage {
        @Test
        func `A vertex stage in WGSL reads the heap only, and gives its position and what it hands on at each place`() throws {
            let text = try Shader.Compiler.wgsl(`Shader.Compiler Tests`.stages)["vertex_blit"]?.text ?? ""
            #expect(text.contains("@group(0) @binding(0) var<storage, read> heap: array<u32>;"))
            #expect(text.contains("shader_position = vec4<f32>(0x1.0p0f, 0.0f, 0.0f, 0x1.0p0f);"))
            #expect(text.contains("shader_f2 = vec4<u32>(bitcast<u32>(l1), bitcast<u32>(t1), 0u, 0u);"))
            #expect(
                text.hasSuffix(
                    """
                    struct Shader_Handed {
                        @builtin(position) position: vec4<f32>,
                        @location(0) v0: vec4<f32>,
                        @location(2) @interpolate(flat) f2: vec4<u32>,
                    }

                    @vertex
                    fn vertex_blit(@builtin(vertex_index) corner: u32, @builtin(instance_index) instance: u32) -> Shader_Handed {
                        shader_10(i32(corner), i32(instance));
                        return Shader_Handed(shader_position, shader_v0, shader_f2);
                    }

                    """
                )
            )
        }

        @Test
        func `A fragment stage in WGSL samples a texture of group 1 in the texture's own measure, and gives a colour`() throws {
            let text = try Shader.Compiler.wgsl(`Shader.Compiler Tests`.stages)["fragment_blit"]?.text ?? ""
            #expect(text.contains("@group(0) @binding(4) var shader_sampler: sampler;"))
            #expect(text.contains("@group(1) @binding(3) var shader_texture3: texture_2d<f32>;"))
            #expect(
                text.contains(
                    "shader_texel = textureSampleLevel(shader_texture3, shader_sampler, vec2<f32>(l0, l1) / vec2<f32>(textureDimensions(shader_texture3)), 0.0f);"
                )
            )
            #expect(
                text.hasSuffix(
                    """
                    @fragment
                    fn fragment_blit(@builtin(position) at: vec4<f32>, @location(2) @interpolate(flat) f2: vec4<u32>) -> @location(0) vec4<f32> {
                        shader_f2 = f2;
                        shader_11(at.x, at.y);
                        return shader_color;
                    }

                    """
                )
            )
        }

        @Test
        func `A kernel in WGSL reads one texture at a place and writes another`() throws {
            let text = try Shader.Compiler.wgsl(`Shader.Compiler Tests`.stages)["copy"]?.text ?? ""
            #expect(text.contains("@group(1) @binding(5) var shader_texture5: texture_storage_2d<rgba16float, write>;"))
            #expect(text.contains("shader_texel = textureLoad(shader_texture1, vec2<u32>(bitcast<u32>(l0), bitcast<u32>(l1)), 0i);"))
            #expect(text.contains("textureStore(shader_texture5, vec2<u32>(bitcast<u32>(l0), bitcast<u32>(l1)), vec4<f32>(t1, t2, t3, t4));"))
        }

        @Test
        func `Stages in Metal's language take their textures one after the surface's place, and hand on a structure`() throws {
            let text = try Shader.Compiler.metal(`Shader.Compiler Tests`.stages).text
            #expect(
                text.contains(
                    """
                    struct Shader_Handed_blit {
                        float4 position [[position]];
                        float4 v0 [[user(locn0)]];
                        uint4 f2 [[user(locn2), flat]];
                    };

                    vertex Shader_Handed_blit vertex_blit(uint corner [[vertex_id]], uint instance [[instance_id]], device const uint * b4 [[buffer(4)]]) {
                    """
                )
            )
            #expect(
                text.contains(
                    "fragment float4 fragment_blit(Shader_Taken_blit taken [[stage_in]], texture2d<float> t3 [[texture(4)]], sampler between [[sampler(0)]]) {"
                )
            )
            #expect(text.contains("s.texel = s.t3.sample(s.between, float2(l0, l1) / float2(s.t3.get_width(), s.t3.get_height()));"))
            #expect(text.contains("kernel void copy(texture2d<float> t1 [[texture(2)]], texture2d<float, access::write> u5 [[texture(6)]], uint2 id [[thread_position_in_grid]]) {"))
            #expect(text.contains("    float4 v0;\n    uint4 f2;\n"))
        }

        @Test
        func `A stage that writes a buffer is refused by name`() {
            var module = `Shader.Compiler Tests`.stages
            module.imports.append(.init(module: "shader", name: "store", kind: .function(9)))
            module.functions = module.functions.map { function in
                var function = function
                function.body = function.body.map { instruction in
                    if case .call(let callee) = instruction, callee >= 10 { return .call(callee + 1) }
                    return instruction
                }
                return function
            }
            module.exports = module.exports.map { .init(name: $0.name, kind: $0.kind, index: $0.index + 1) }
            module.functions[0].body += [.i32(4), .i32(0), .i32(1), .call(10)]
            #expect(throws: Shader.Compiler.Error.stage(entry: "vertex_blit")) { _ = try Shader.Compiler.wgsl(module) }
            #expect(throws: Shader.Compiler.Error.stage(entry: "vertex_blit")) { _ = try Shader.Compiler.metal(module) }
        }
    }
}
