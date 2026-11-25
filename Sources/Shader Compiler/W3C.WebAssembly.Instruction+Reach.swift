internal import W3C_WebAssembly

extension [W3C.WebAssembly.Instruction] {
    /// Every instruction, those in blocks with them.
    private func each(_ body: (Element) -> Void) {
        for instruction in self {
            body(instruction)
            switch instruction {
            case .block(_, let inner), .loop(_, let inner): inner.each(body)
            case .if(_, let then, let otherwise):
                then.each(body)
                otherwise.each(body)
            default: break
            }
        }
    }

    /// The functions called.
    var callees: Set<Int> {
        var callees: Set<Int> = []
        each { if case .call(let callee) = $0 { callees.insert(callee) } }
        return callees
    }

    /// The locals given another value.
    var assigned: Set<Int> {
        var assigned: Set<Int> = []
        each { instruction in
            switch instruction {
            case .localSet(let local), .localTee(let local): assigned.insert(local)
            default: break
            }
        }
        return assigned
    }
}
