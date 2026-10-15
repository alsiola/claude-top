import Foundation

/// A JSON value that keeps object key order and number text, so that an edit to
/// `~/.claude/settings.json` changes only the parts that the installer touches.
public indirect enum JSON: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(String)
    case string(String)
    case array([JSON])
    case object([Member])

    public struct Member: Equatable, Sendable {
        public var key: String
        public var value: JSON

        public init(_ key: String, _ value: JSON) {
            self.key = key
            self.value = value
        }
    }

    public subscript(key: String) -> JSON? {
        get {
            guard case .object(let members) = self else { return nil }
            return members.first { $0.key == key }?.value
        }
        set {
            guard case .object(var members) = self else { return }
            if let index = members.firstIndex(where: { $0.key == key }) {
                if let newValue {
                    members[index].value = newValue
                } else {
                    members.remove(at: index)
                }
            } else if let newValue {
                members.append(Member(key, newValue))
            }
            self = .object(members)
        }
    }

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var arrayValue: [JSON]? {
        if case .array(let value) = self { return value }
        return nil
    }

    public var isObject: Bool {
        if case .object = self { return true }
        return false
    }
}

// MARK: - Parse

public struct JSONParseError: Error, CustomStringConvertible {
    public let offset: Int
    public let reason: String
    public var description: String { "Invalid JSON at byte \(offset): \(reason)" }
}

extension JSON {
    public static func parse(_ data: Data) throws -> JSON {
        var parser = Parser(bytes: [UInt8](data))
        parser.skipWhitespace()
        let value = try parser.parseValue()
        parser.skipWhitespace()
        guard parser.index == parser.bytes.count else {
            throw parser.error("unexpected data after the end")
        }
        return value
    }

    public static func parse(_ text: String) throws -> JSON {
        try parse(Data(text.utf8))
    }
}

private struct Parser {
    let bytes: [UInt8]
    var index = 0
    var depth = 0

    init(bytes: [UInt8]) {
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            self.bytes = Array(bytes.dropFirst(3))
        } else {
            self.bytes = bytes
        }
    }

    func error(_ reason: String) -> JSONParseError {
        JSONParseError(offset: index, reason: reason)
    }

    mutating func skipWhitespace() {
        while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) {
            index += 1
        }
    }

    mutating func parseValue() throws -> JSON {
        guard index < bytes.count else { throw error("unexpected end") }
        switch bytes[index] {
        case UInt8(ascii: "{"): return try parseObject()
        case UInt8(ascii: "["): return try parseArray()
        case UInt8(ascii: "\""): return .string(try parseString())
        case UInt8(ascii: "t"): try expect("true"); return .bool(true)
        case UInt8(ascii: "f"): try expect("false"); return .bool(false)
        case UInt8(ascii: "n"): try expect("null"); return .null
        case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"): return try parseNumber()
        default: throw error("unexpected character")
        }
    }

    mutating func expect(_ literal: String) throws {
        let literalBytes = Array(literal.utf8)
        guard index + literalBytes.count <= bytes.count,
              Array(bytes[index..<index + literalBytes.count]) == literalBytes
        else { throw error("expected \(literal)") }
        index += literalBytes.count
    }

    mutating func enter() throws {
        depth += 1
        if depth > 512 { throw error("nesting is too deep") }
    }

    mutating func parseObject() throws -> JSON {
        try enter()
        defer { depth -= 1 }
        index += 1
        var members: [JSON.Member] = []
        skipWhitespace()
        if index < bytes.count, bytes[index] == UInt8(ascii: "}") {
            index += 1
            return .object(members)
        }
        while true {
            skipWhitespace()
            guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else {
                throw error("expected a key")
            }
            let key = try parseString()
            skipWhitespace()
            guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else {
                throw error("expected ':'")
            }
            index += 1
            skipWhitespace()
            members.append(JSON.Member(key, try parseValue()))
            skipWhitespace()
            guard index < bytes.count else { throw error("unexpected end") }
            if bytes[index] == UInt8(ascii: ",") {
                index += 1
            } else if bytes[index] == UInt8(ascii: "}") {
                index += 1
                return .object(members)
            } else {
                throw error("expected ',' or '}'")
            }
        }
    }

    mutating func parseArray() throws -> JSON {
        try enter()
        defer { depth -= 1 }
        index += 1
        var items: [JSON] = []
        skipWhitespace()
        if index < bytes.count, bytes[index] == UInt8(ascii: "]") {
            index += 1
            return .array(items)
        }
        while true {
            skipWhitespace()
            items.append(try parseValue())
            skipWhitespace()
            guard index < bytes.count else { throw error("unexpected end") }
            if bytes[index] == UInt8(ascii: ",") {
                index += 1
            } else if bytes[index] == UInt8(ascii: "]") {
                index += 1
                return .array(items)
            } else {
                throw error("expected ',' or ']'")
            }
        }
    }

    mutating func parseNumber() throws -> JSON {
        let start = index
        if bytes[index] == UInt8(ascii: "-") { index += 1 }
        func digits() -> Int {
            let from = index
            while index < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[index]) {
                index += 1
            }
            return index - from
        }
        guard digits() > 0 else { throw error("expected a digit") }
        if index < bytes.count, bytes[index] == UInt8(ascii: ".") {
            index += 1
            guard digits() > 0 else { throw error("expected a digit") }
        }
        if index < bytes.count, bytes[index] == UInt8(ascii: "e") || bytes[index] == UInt8(ascii: "E") {
            index += 1
            if index < bytes.count, bytes[index] == UInt8(ascii: "+") || bytes[index] == UInt8(ascii: "-") {
                index += 1
            }
            guard digits() > 0 else { throw error("expected a digit") }
        }
        return .number(String(decoding: bytes[start..<index], as: UTF8.self))
    }

    mutating func parseHex4() throws -> UInt32 {
        guard index + 4 <= bytes.count,
              let value = UInt32(String(decoding: bytes[index..<index + 4], as: UTF8.self), radix: 16)
        else { throw error("bad \\u escape") }
        index += 4
        return value
    }

    mutating func parseString() throws -> String {
        index += 1
        var buffer: [UInt8] = []
        while true {
            guard index < bytes.count else { throw error("unterminated string") }
            let byte = bytes[index]
            index += 1
            switch byte {
            case UInt8(ascii: "\""):
                return String(decoding: buffer, as: UTF8.self)
            case UInt8(ascii: "\\"):
                guard index < bytes.count else { throw error("unterminated string") }
                let escape = bytes[index]
                index += 1
                switch escape {
                case UInt8(ascii: "\""): buffer.append(UInt8(ascii: "\""))
                case UInt8(ascii: "\\"): buffer.append(UInt8(ascii: "\\"))
                case UInt8(ascii: "/"): buffer.append(UInt8(ascii: "/"))
                case UInt8(ascii: "b"): buffer.append(0x08)
                case UInt8(ascii: "f"): buffer.append(0x0C)
                case UInt8(ascii: "n"): buffer.append(0x0A)
                case UInt8(ascii: "r"): buffer.append(0x0D)
                case UInt8(ascii: "t"): buffer.append(0x09)
                case UInt8(ascii: "u"):
                    var scalar = try parseHex4()
                    if (0xD800...0xDBFF).contains(scalar),
                       index + 1 < bytes.count,
                       bytes[index] == UInt8(ascii: "\\"),
                       bytes[index + 1] == UInt8(ascii: "u") {
                        index += 2
                        let low = try parseHex4()
                        guard (0xDC00...0xDFFF).contains(low) else { throw error("bad surrogate pair") }
                        scalar = 0x10000 + ((scalar - 0xD800) << 10) + (low - 0xDC00)
                    }
                    let character = Unicode.Scalar(scalar) ?? "\u{FFFD}"
                    buffer.append(contentsOf: Array(String(character).utf8))
                default:
                    throw error("bad escape")
                }
            case 0x00..<0x20:
                throw error("control character in string")
            default:
                buffer.append(byte)
            }
        }
    }
}

// MARK: - Serialize

extension JSON {
    /// Pretty output with two-space indent, the format that Claude Code writes.
    public func serialized() -> String {
        var output = ""
        write(to: &output, indent: 0)
        output += "\n"
        return output
    }

    private func write(to output: inout String, indent: Int) {
        switch self {
        case .null: output += "null"
        case .bool(let value): output += value ? "true" : "false"
        case .number(let text): output += text
        case .string(let value): JSON.writeString(value, to: &output)
        case .array(let items):
            if items.isEmpty { output += "[]"; return }
            output += "[\n"
            for (offset, item) in items.enumerated() {
                output += String(repeating: "  ", count: indent + 1)
                item.write(to: &output, indent: indent + 1)
                output += offset < items.count - 1 ? ",\n" : "\n"
            }
            output += String(repeating: "  ", count: indent) + "]"
        case .object(let members):
            if members.isEmpty { output += "{}"; return }
            output += "{\n"
            for (offset, member) in members.enumerated() {
                output += String(repeating: "  ", count: indent + 1)
                JSON.writeString(member.key, to: &output)
                output += ": "
                member.value.write(to: &output, indent: indent + 1)
                output += offset < members.count - 1 ? ",\n" : "\n"
            }
            output += String(repeating: "  ", count: indent) + "}"
        }
    }

    private static func writeString(_ value: String, to output: inout String) {
        output += "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": output += "\\\""
            case "\\": output += "\\\\"
            case "\n": output += "\\n"
            case "\r": output += "\\r"
            case "\t": output += "\\t"
            case "\u{08}": output += "\\b"
            case "\u{0C}": output += "\\f"
            case _ where scalar.value < 0x20:
                output += String(format: "\\u%04x", scalar.value)
            default:
                output.unicodeScalars.append(scalar)
            }
        }
        output += "\""
    }
}
