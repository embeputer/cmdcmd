import Foundation

/// A `Sendable` JSON value for ACP wire traffic. `Any`-typed dictionaries from
/// JSONSerialization can't cross actor boundaries, so messages live in this
/// enum and bridge to/from `Any` only at the (de)serialization edge.
indirect enum JSONValue: Sendable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case null

    // MARK: bridging

    init(_ any: Any?) {
        switch any {
        case let d as [String: Any]:
            self = .object(d.mapValues { JSONValue($0) })
        case let a as [Any]:
            self = .array(a.map { JSONValue($0) })
        case let n as NSNumber:
            // NSNumber must be disambiguated BEFORE Bool/Int casts: bridging an
            // NSNumber(1) `as Bool` succeeds, which would swallow JSON ids 0/1.
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                self = .bool(n.boolValue)
            } else if n.doubleValue == Double(n.intValue) {
                self = .int(n.intValue)
            } else {
                self = .double(n.doubleValue)
            }
        case let s as String:
            self = .string(s)
        case _ as NSNull:
            self = .null
        case .none:
            self = .null
        default:
            self = .null
        }
    }

    /// Convert back to `Any` graph for JSONSerialization.
    var anyObject: Any {
        switch self {
        case .object(let d): return d.mapValues { $0.anyObject }
        case .array(let a): return a.map { $0.anyObject }
        case .string(let s): return s
        case .int(let i): return i
        case .double(let d): return d
        case .bool(let b): return b
        case .null: return NSNull()
        }
    }

    // MARK: accessors

    subscript(key: String) -> JSONValue? {
        if case .object(let d) = self { return d[key] }
        return nil
    }

    subscript(index: Int) -> JSONValue? {
        if case .array(let a) = self, index >= 0, index < a.count { return a[index] }
        return nil
    }

    var string: String? { if case .string(let s) = self { return s }; return nil }
    var int: Int? {
        switch self {
        case .int(let i): return i
        case .double(let d): return Int(d)
        default: return nil
        }
    }
    var double: Double? {
        switch self {
        case .int(let i): return Double(i)
        case .double(let d): return d
        default: return nil
        }
    }
    var bool: Bool? { if case .bool(let b) = self { return b }; return nil }
    var dict: [String: JSONValue]? { if case .object(let d) = self { return d }; return nil }
    var array: [JSONValue]? { if case .array(let a) = self { return a }; return nil }

    var stringValue: String {
        switch self {
        case .string(let s): return s
        case .int(let i): return String(i)
        case .double(let d): return String(d)
        case .bool(let b): return String(b)
        default: return ""
        }
    }

    // MARK: literal building

    static func obj(_ pairs: (String, JSONValue)...) -> JSONValue {
        .object(Dictionary(uniqueKeysWithValues: pairs))
    }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral,
                    ExpressibleByFloatLiteral, ExpressibleByBooleanLiteral,
                    ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral,
                    ExpressibleByNilLiteral {
    init(stringLiteral value: String) { self = .string(value) }
    init(integerLiteral value: Int) { self = .int(value) }
    init(floatLiteral value: Double) { self = .double(value) }
    init(booleanLiteral value: Bool) { self = .bool(value) }
    init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(uniqueKeysWithValues: elements))
    }
    init(nilLiteral: ()) { self = .null }
}
