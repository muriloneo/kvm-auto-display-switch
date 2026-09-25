/// MCCS capabilities string, e.g.
/// `(prot(monitor)type(lcd)model(X)cmds(01 02)vcp(02 10 60( 11 12 0F 10) ...)mccs_ver(2.1))`
public struct Capabilities: Equatable {
    public let raw: String
    public let model: String?
    public let mccsVersion: String?
    /// VCP code -> advertised discrete values (empty when the code takes a continuous range).
    public let vcp: [UInt8: [UInt16]]

    public var advertisedInputValues: [UInt16] { vcp[DDC.vcpInputSource] ?? [] }

    public init(parsing raw: String) {
        self.raw = raw
        model = Capabilities.tag("model", in: raw)
        mccsVersion = Capabilities.tag("mccs_ver", in: raw)
        vcp = Capabilities.tag("vcp", in: raw).map(Capabilities.parseVCP) ?? [:]
    }

    /// Returns the balanced-paren contents of `name(...)`.
    static func tag(_ name: String, in raw: String) -> String? {
        let chars = Array(raw)
        let key = Array(name + "(")
        var i = 0
        while i + key.count <= chars.count {
            let preceded = i == 0 || !(chars[i - 1].isLetter || chars[i - 1] == "_")
            if preceded && Array(chars[i..<i + key.count]) == key {
                var depth = 1
                var j = i + key.count
                let start = j
                while j < chars.count && depth > 0 {
                    if chars[j] == "(" { depth += 1 }
                    if chars[j] == ")" { depth -= 1 }
                    j += 1
                }
                guard depth == 0 else { return nil }
                return String(chars[start..<(j - 1)])
            }
            i += 1
        }
        return nil
    }

    static func parseVCP(_ body: String) -> [UInt8: [UInt16]] {
        var result: [UInt8: [UInt16]] = [:]
        var lastCode: UInt8?
        var token = ""
        var inValues = false
        var values: [UInt16] = []

        func flushToken() {
            defer { token = "" }
            guard !token.isEmpty, let v = UInt16(token, radix: 16) else { return }
            if inValues {
                values.append(v)
            } else if v <= 0xFF {
                lastCode = UInt8(v)
                result[UInt8(v)] = []
            }
        }

        for c in body {
            switch c {
            case "(":
                flushToken()
                inValues = true
                values = []
            case ")":
                flushToken()
                if let code = lastCode { result[code] = values }
                inValues = false
            case " ":
                flushToken()
            default:
                token.append(c)
            }
        }
        flushToken()
        return result
    }
}
