import Foundation

/// Errors thrown while reading a devalue-serialized payload.
enum DevalueError: Error, Equatable {
    case invalidInput
    /// A devalue "tagged" value (Date, Set, Map, BigInt, TypedArray, …) that this
    /// reader doesn't handle. Civitai's image/post/collection/tag/user responses
    /// are plain JSON and never carry these; surfacing rather than guessing keeps
    /// a future server change from being silently mis-decoded.
    case unknownType(String)
    case circularReference
    case prototypeKey
}

/// Reads the [devalue](https://github.com/Rich-Harris/devalue) serialization
/// format (`devalue.stringify` output) into a Foundation object graph
/// (`NSDictionary`/`NSArray`/`NSNumber`/`NSString`/`NSNull`).
///
/// As of 2026-07 Civitai serializes its tRPC **responses** with devalue instead
/// of superjson (their PR #3135, "Phase 2 — flip WRITE to devalue"): `result.data`
/// arrives as a *string* holding a flattened, index-referenced array rather than a
/// `{ "json": … }` object. `TRPCEnvelope.normalize` uses this reader to turn that
/// string back into the payload the app's decoders expect. This is a faithful port
/// of devalue 5.8.1's `unflatten` for the plain-JSON subset the API actually emits.
///
/// The flattened form is a JSON array where element 0 is the root and every
/// number in a structural position is an *index* into the array (this is how
/// devalue dedupes and preserves shared references); actual scalars live at their
/// own index. Negative indices are sentinels (undefined, hole, NaN, ±Infinity, -0).
enum DevalueDecoder {

    // devalue 5.8.1 constants (src/constants.js).
    private static let UNDEFINED = -1
    private static let HOLE = -2
    private static let NAN = -3
    private static let POSITIVE_INFINITY = -4
    private static let NEGATIVE_INFINITY = -5
    private static let NEGATIVE_ZERO = -6
    private static let SPARSE = -7

    /// Identity marker for JS `undefined`. Distinct from `NSNull` (JSON `null`):
    /// an `undefined` object value is *omitted* and an `undefined` array element
    /// becomes `null`, matching `JSON.stringify`.
    private final class Undefined {}
    private static let undefinedMarker = Undefined()

    /// Parses a `devalue.stringify` string. Returns `nil` only for a payload that
    /// is itself `undefined`.
    static func parse(_ string: String) throws -> Any? {
        guard let data = string.data(using: .utf8) else { throw DevalueError.invalidInput }
        let top = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        let result = try unflatten(top)
        return isUndefined(result) ? nil : result
    }

    private static func isUndefined(_ value: Any) -> Bool {
        (value as AnyObject) === undefinedMarker
    }

    private static func unflatten(_ parsed: Any) throws -> Any {
        // A bare top-level number is only ever a standalone sentinel (e.g. a
        // payload that is `undefined`), never a real value — real values are
        // wrapped in the flattened array.
        if let number = parsed as? NSNumber, !isBoolean(number) {
            return try standalone(number.intValue)
        }

        guard let values = parsed as? [Any], !values.isEmpty else {
            throw DevalueError.invalidInput
        }

        var hydrated = [Int: Any]()

        func hydrate(_ index: Int) throws -> Any {
            switch index {
            case UNDEFINED: return undefinedMarker
            case NAN: return NSNumber(value: Double.nan)
            case POSITIVE_INFINITY: return NSNumber(value: Double.infinity)
            case NEGATIVE_INFINITY: return NSNumber(value: -Double.infinity)
            case NEGATIVE_ZERO: return NSNumber(value: -0.0)
            default: break
            }

            guard index >= 0, index < values.count else { throw DevalueError.invalidInput }
            if let cached = hydrated[index] { return cached }

            let value = values[index]

            // Object map: { key: index, … }
            if let object = value as? [String: Any] {
                let result = NSMutableDictionary()
                hydrated[index] = result // memoize before recursing (cycle-safe)
                for (key, child) in object {
                    if key == "__proto__" { throw DevalueError.prototypeKey }
                    guard let childIndex = intIndex(child) else { throw DevalueError.invalidInput }
                    let hydratedChild = try hydrate(childIndex)
                    // A key whose value is `undefined` is dropped (JSON has no undefined).
                    if isUndefined(hydratedChild) { continue }
                    result[key] = hydratedChild
                }
                return result
            }

            // Array-ish: regular array, tagged type, or sparse array.
            if let array = value as? [Any] {
                if let tag = array.first as? String {
                    return try hydrateTagged(tag, array)
                }
                if let first = array.first, intIndex(first) == SPARSE {
                    return try hydrateSparse(array, into: index)
                }
                let result = NSMutableArray()
                hydrated[index] = result
                for element in array {
                    guard let elementIndex = intIndex(element) else { throw DevalueError.invalidInput }
                    if elementIndex == HOLE {
                        result.add(NSNull())
                        continue
                    }
                    let hydratedElement = try hydrate(elementIndex)
                    // `undefined` array elements become `null`, like JSON.stringify.
                    result.add(isUndefined(hydratedElement) ? NSNull() : hydratedElement)
                }
                return result
            }

            // A scalar stored at its own index (string, number, bool, null).
            hydrated[index] = value
            return value
        }

        /// Reviver for devalue's string-tagged values. Handles the JSON-adjacent
        /// tags the API could plausibly use; everything else surfaces as
        /// `unknownType` rather than being silently coerced.
        func hydrateTagged(_ tag: String, _ array: [Any]) throws -> Any {
            switch tag {
            case "Date":
                // Represent as an ISO-8601 string — the app's models decode dates
                // as strings. `value[1]` is already an ISO string on the wire.
                if let iso = array.count > 1 ? array[1] as? String : nil { return iso }
                throw DevalueError.unknownType(tag)
            case "BigInt":
                if array.count > 1, let s = array[1] as? String {
                    if let i = Int64(s) { return NSNumber(value: i) }
                    return s
                }
                throw DevalueError.unknownType(tag)
            case "null":
                // Null-prototype object: ["null", key, valueIndex, …]
                let result = NSMutableDictionary()
                var i = 1
                while i + 1 < array.count {
                    guard let key = array[i] as? String else { throw DevalueError.invalidInput }
                    if key == "__proto__" { throw DevalueError.prototypeKey }
                    guard let valueIndex = intIndex(array[i + 1]) else { throw DevalueError.invalidInput }
                    let hydratedValue = try hydrate(valueIndex)
                    if !isUndefined(hydratedValue) { result[key] = hydratedValue }
                    i += 2
                }
                return result
            default:
                throw DevalueError.unknownType(tag)
            }
        }

        /// Sparse array: [SPARSE, length, index, valueIndex, …]. Rare in JSON data,
        /// handled for completeness. Unset slots surface as `NSNull`.
        func hydrateSparse(_ array: [Any], into index: Int) throws -> Any {
            guard array.count >= 2, let length = intIndex(array[1]), length >= 0 else {
                throw DevalueError.invalidInput
            }
            let result = NSMutableArray()
            hydrated[index] = result
            for _ in 0..<length { result.add(NSNull()) }
            var i = 2
            while i + 1 < array.count {
                guard let slot = intIndex(array[i]), slot >= 0, slot < length else {
                    throw DevalueError.invalidInput
                }
                guard let valueIndex = intIndex(array[i + 1]) else { throw DevalueError.invalidInput }
                result[slot] = try hydrate(valueIndex)
                i += 2
            }
            return result
        }

        return try hydrate(0)
    }

    private static func standalone(_ index: Int) throws -> Any {
        switch index {
        case UNDEFINED: return undefinedMarker
        case NAN: return NSNumber(value: Double.nan)
        case POSITIVE_INFINITY: return NSNumber(value: Double.infinity)
        case NEGATIVE_INFINITY: return NSNumber(value: -Double.infinity)
        case NEGATIVE_ZERO: return NSNumber(value: -0.0)
        default: throw DevalueError.invalidInput
        }
    }

    /// A structural position must hold an integer index. Booleans (also `NSNumber`)
    /// are never indices, so they're rejected here.
    private static func intIndex(_ value: Any) -> Int? {
        guard let number = value as? NSNumber, !isBoolean(number) else { return nil }
        return number.intValue
    }

    private static func isBoolean(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }
}

/// Normalizes a tRPC batch response so every element's `result.data` is the
/// superjson-shaped `{ "json": … }` object the app's envelope decoders expect —
/// regardless of whether the server wrote superjson or devalue. This mirrors the
/// union READ Civitai's own clients use (`unionDeserialize` in their
/// `trpc-union-transformer.ts`): a **string** `data` is devalue, an **object**
/// `data` is superjson.
///
/// Fail-open: any element that can't be parsed/converted is passed through
/// untouched, so normalization is never worse than doing nothing.
enum TRPCEnvelope {
    static func normalize(_ data: Foundation.Data) -> Foundation.Data {
        guard let top = try? JSONSerialization.jsonObject(with: data),
              let batch = top as? [Any] else {
            return data
        }

        var changed = false
        var out = [Any]()
        out.reserveCapacity(batch.count)

        for element in batch {
            // `try?` flattens the parser's `Any?` result: this binds only when the
            // element is a devalue result whose payload parses to a non-nil value.
            guard var object = element as? [String: Any],
                  var result = object["result"] as? [String: Any],
                  let devalueString = result["data"] as? String,
                  let payload = try? DevalueDecoder.parse(devalueString) else {
                // Not a devalue result envelope (superjson, an error element, or
                // an undecodable payload) — leave it exactly as received.
                out.append(element)
                continue
            }
            result["data"] = ["json": payload]
            object["result"] = result
            out.append(object)
            changed = true
        }

        guard changed, let normalized = try? JSONSerialization.data(withJSONObject: out) else {
            return data
        }
        return normalized
    }
}
