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
    /// Catch-all for unparseable payloads (used by protocol fields that may
    /// arrive in non-standard shapes). Preserves the raw JSON Data for debug.
    case unknown(Data)

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let n = try? c.decode(Double.self) { self = .number(n); return }
        if let s = try? c.decode(String.self) { self = .string(s); return }
        if let a = try? c.decode([JSONValue].self) { self = .array(a); return }
        if let o = try? c.decode([String: JSONValue].self) { self = .object(o); return }
        // Graceful fallback — preserve raw bytes instead of losing the value.
        if let d = try? c.decode(Data.self) {
            self = .unknown(d)
        } else {
            self = .unknown(Data())
        }
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
        case .unknown(let d): try c.encode(d)
        }
    }
}

extension JSONValue {
    subscript(_ key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    var asString: String? {
        switch self {
        case .string(let s): return s
        case .number(let n): return n == n.rounded() ? String(Int(n)) : String(n)
        case .bool(let b): return String(b)
        case .unknown(let d): return String(data: d, encoding: .utf8)
        default: return nil
        }
    }

    var asNumber: Double? {
        switch self {
        case .number(let n): return n
        case .string(let s): return Double(s)
        case .bool(let b): return b ? 1.0 : 0.0
        default: return nil
        }
    }

    var asObject: [String: JSONValue]? {
        if case .object(let o) = self { return o }
        return nil
    }

    /// Raw preserved bytes (only non-nil for .unknown payloads).
    var raw: Data? { if case .unknown(let d) = self { return d } else { return nil } }

    /// Human-readable multi-line rendering for tool inputs / debug panes.
    func pretty() -> String {
        switch self {
        case .string(let s): return s
        case .null: return "null"
        case .bool(let b): return String(b)
        case .number(let n): return n == n.rounded() ? String(Int(n)) : String(n)
        case .unknown(let d):
            if let s = String(data: d, encoding: .utf8) { return s }
            return "<\(d.count)-byte binary payload>"
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
