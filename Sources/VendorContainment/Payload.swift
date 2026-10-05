import Foundation

/// A vendor configuration payload, modelled as JSON-shaped data.
public indirect enum PayloadValue: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([PayloadValue])
    case object([String: PayloadValue])
}

public typealias VendorPayload = [String: PayloadValue]

/// What an adapter promises its SDK will tolerate.
///
/// The Firebase postmortem's root cause was a `nil` flag name reaching code
/// that assumed it was present. The schema makes "these keys must be present,
/// must be strings, and must be non-empty" an app-owned check that runs
/// *before* the SDK sees the payload.
public struct PayloadSchema: Sendable, Equatable {
    public var requiredNonEmptyStrings: Set<String>
    public var maxDepth: Int
    public var maxNodes: Int
    public var maxStringBytes: Int

    public init(
        requiredNonEmptyStrings: Set<String> = [],
        maxDepth: Int = 8,
        maxNodes: Int = 2_000,
        maxStringBytes: Int = 4_096
    ) {
        self.requiredNonEmptyStrings = requiredNonEmptyStrings
        self.maxDepth = maxDepth
        self.maxNodes = maxNodes
        self.maxStringBytes = maxStringBytes
    }

    public static let permissive = PayloadSchema()
}

public enum PayloadViolation: Sendable, Equatable, CustomStringConvertible {
    case missingKey(String)
    case nullValue(String)
    case wrongType(String)
    case emptyString(String)
    case tooDeep(limit: Int)
    case tooManyNodes(limit: Int)
    case stringTooLong(limit: Int)
    case invalidSchema

    public var description: String {
        switch self {
        case .missingKey(let k): "missing required key '\(k)'"
        case .nullValue(let k): "required key '\(k)' is null"
        case .wrongType(let k): "required key '\(k)' is not a string"
        case .emptyString(let k): "required key '\(k)' is empty"
        case .tooDeep(let l): "nesting deeper than \(l)"
        case .tooManyNodes(let l): "more than \(l) nodes"
        case .stringTooLong(let l): "a string longer than \(l) bytes"
        case .invalidSchema: "schema limits must be positive"
        }
    }
}

public enum PayloadValidator {
    /// Validates `payload` against `schema`. Returns the required-key
    /// violations (sorted by key) followed by the first structural violation
    /// found, or an empty array if the payload is safe. Object members are
    /// walked in key order, so the result is deterministic.
    ///
    /// The walk is iterative with an explicit stack and checks width before
    /// allocating, so validation itself never recurses and stops as soon as
    /// a structural limit is crossed. (Scope: this bounds *validation*.
    /// Building, decoding, comparing or freeing a pathologically deep
    /// `indirect enum` value is still recursive in Swift, so the code that
    /// decodes vendor JSON into `PayloadValue` should cap depth as it goes.)
    public static func validate(_ payload: VendorPayload, against schema: PayloadSchema) -> [PayloadViolation] {
        guard schema.maxDepth > 0, schema.maxNodes > 0, schema.maxStringBytes > 0 else {
            return [.invalidSchema]
        }
        var violations: [PayloadViolation] = []

        for key in schema.requiredNonEmptyStrings.sorted() {
            switch payload[key] {
            case .none: violations.append(.missingKey(key))
            case .some(.null): violations.append(.nullValue(key))
            case .some(.string(let s)) where s.isEmpty: violations.append(.emptyString(key))
            case .some(.string): break
            case .some: violations.append(.wrongType(key))
            }
        }

        if payload.keys.contains(where: { $0.utf8.count > schema.maxStringBytes }) {
            violations.append(.stringTooLong(limit: schema.maxStringBytes))
            return violations
        }
        guard payload.count <= schema.maxNodes else {
            violations.append(.tooManyNodes(limit: schema.maxNodes))
            return violations
        }
        // Reversed so that popLast() visits keys in ascending order.
        var stack: [(PayloadValue, Int)] = payload.sorted { $0.key < $1.key }.reversed().map { ($0.value, 1) }
        var nodes = 0
        while let (value, depth) = stack.popLast() {
            nodes = Saturating.increment(nodes)
            if nodes > schema.maxNodes {
                violations.append(.tooManyNodes(limit: schema.maxNodes))
                break
            }
            if depth > schema.maxDepth {
                violations.append(.tooDeep(limit: schema.maxDepth))
                break
            }
            switch value {
            case .string(let s) where s.utf8.count > schema.maxStringBytes:
                violations.append(.stringTooLong(limit: schema.maxStringBytes))
                return violations
            case .array(let items):
                // Check width before allocating stack entries for it.
                guard Saturating.add(Saturating.add(nodes, stack.count), items.count) <= schema.maxNodes else {
                    violations.append(.tooManyNodes(limit: schema.maxNodes))
                    return violations
                }
                let next = Saturating.increment(depth)
                stack.append(contentsOf: items.reversed().map { ($0, next) })
            case .object(let dict):
                guard Saturating.add(Saturating.add(nodes, stack.count), dict.count) <= schema.maxNodes else {
                    violations.append(.tooManyNodes(limit: schema.maxNodes))
                    return violations
                }
                if dict.keys.contains(where: { $0.utf8.count > schema.maxStringBytes }) {
                    violations.append(.stringTooLong(limit: schema.maxStringBytes))
                    return violations
                }
                let next = Saturating.increment(depth)
                stack.append(contentsOf: dict.sorted { $0.key < $1.key }.reversed().map { ($0.value, next) })
            default:
                break
            }
        }
        return violations
    }
}
