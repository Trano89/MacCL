import Foundation

/// A lightweight, loss-tolerant representation of arbitrary JSON.
/// Used for dynamically-shaped fields in the stream-json protocol such as
/// tool inputs, usage stats, and control-protocol payloads.
enum JSONValue: Codable, Equatable, Hashable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let n = try? c.decode(Double.self) { self = .number(n); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let a = try? c.decode([JSONValue].self) { self = .array(a); return }
        if let o = try? c.decode([String: JSONValue].self) { self = .object(o); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported JSON value")
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}

extension JSONValue {
    subscript(_ key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    /// A number as text, never through `Int(_:)`, which TRAPS outside Int's
    /// range: the stream is external input and `Int(1e300)` crashed the app
    /// once already. That fix lived only in `asString`, while `pretty()` kept
    /// the trapping form — and `pretty()` is what renders every tool card — so
    /// the conversion now has one home that every path goes through.
    /// Infinity takes the same route: `inf == inf.rounded()` is true, and
    /// `Int(exactly: inf)` is nil rather than a trap.
    static func numberText(_ n: Double) -> String {
        if n == n.rounded(), let i = Int(exactly: n.rounded()) { return String(i) }
        return String(n)
    }

    var asString: String? {
        switch self {
        case .string(let s): return s
        case .number(let n): return Self.numberText(n)
        case .bool(let b): return String(b)
        default: return nil
        }
    }

    /// The value as an Int when it is a (finite, in-range) number.
    var asInt: Int? {
        if case .number(let n) = self { return Int(exactly: n.rounded()) }
        return nil
    }

    var asObject: [String: JSONValue]? {
        if case .object(let o) = self { return o }
        return nil
    }

    /// Human-readable multi-line rendering for tool inputs / debug panes.
    func pretty() -> String {
        switch self {
        case .string(let s): return s
        case .null: return "null"
        case .bool(let b): return String(b)
        case .number(let n): return Self.numberText(n)
        default:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            if let data = try? encoder.encode(self), let s = String(data: data, encoding: .utf8) {
                return s
            }
            return "\(self)"
        }
    }

    /// One-line summary for compact rows (e.g. a tool call header).
    func oneLineSummary(maxLength: Int = 120) -> String {
        let flat = pretty().replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
        return flat.count > maxLength ? String(flat.prefix(maxLength)) + "…" : flat
    }
}
