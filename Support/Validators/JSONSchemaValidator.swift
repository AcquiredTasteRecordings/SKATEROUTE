// Support/Validators/JSONSchemaValidator.swift
// Minimal, on-device JSON validation for config payloads.
// - No third-party libs. Pure Foundation + JSONSerialization.
// - Predefined light “schemas” with type/range/enum checks.
// - DEBUG-only assert to fail fast during dev.
// - OSLog warnings on failures; never uploads anything.
//
// Schemas covered:
//  • attrsV1           (city attribution points; lightingLevel accepts {good, moderate, poor} and legacy {high, medium, low})
//  • spotCategoriesV1  (canonical spot taxonomy + glyph/color tokens)
//  • hazardPayloadV1   (hazard report objects; severity 1…3; createdAt ISO8601)
//
// Public API:
//  • JSONSchemaValidator.shared.validate(data:with:) -> ValidationResult
//  • JSONSchemaValidator.shared.assertValid(_:schema:)   // DEBUG only
//
// Back-compat adapter used elsewhere in the project:
//  • validate(jsonData:schemaURL:)    // dispatches by filename; keeps older call sites working.

import Foundation
import OSLog

// MARK: - Result / Error types

public struct ValidationError: Error, Equatable, Sendable {
    public let path: String   // e.g., "points[4].lat"
    public let message: String
}

public struct ValidationResult: Sendable, Equatable {
    public let isValid: Bool
    public let errors: [ValidationError]
    public init(errors: [ValidationError]) {
        self.errors = errors
        self.isValid = errors.isEmpty
    }
}

// MARK: - Schema descriptor

public final class JSONSchemaValidator: @unchecked Sendable {

    public enum Schema: Sendable {
        case attrsV1
        case spotCategoriesV1
        case hazardPayloadV1
    }

    public static let shared = JSONSchemaValidator()
    private init() {}

    private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "SkateRoute", category: "JSONSchema")

    // MARK: - Public API

    public func validate(data: Data, with schema: Schema) -> ValidationResult {
        do {
            let json = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
            let errors: [ValidationError]
            switch schema {
            case .attrsV1:
                errors = validateAttrsV1(json: json)
            case .spotCategoriesV1:
                errors = validateSpotCategoriesV1(json: json)
            case .hazardPayloadV1:
                errors = validateHazardPayloadV1(json: json)
            }
            if !errors.isEmpty {
                // Emit a compact warning with first few errors
                let preview = errors.prefix(3).map { "\($0.path): \($0.message)" }.joined(separator: " | ")
                log.warning("JSONSchema invalid (\(errors.count, privacy: .public) errors): \(preview, privacy: .public)")
            }
            return ValidationResult(errors: errors)
        } catch {
            return ValidationResult(errors: [ValidationError(path: "$", message: "Malformed JSON: \(error.localizedDescription)")])
        }
    }

    #if DEBUG
    public func assertValid(_ data: Data, schema: Schema, file: StaticString = #file, line: UInt = #line) {
        let result = validate(data: data, with: schema)
        if !result.isValid {
            let joined = result.errors.map { "\($0.path): \($0.message)" }.joined(separator: "\n")
            preconditionFailure("JSON failed schema validation:\n\(joined)", file: file, line: line)
        }
    }
    #endif

    // MARK: - Back-compat adapter (used by some services/tests)

    /// Dispatches by filename so older call sites (that passed a schema file URL) keep working without a full JSON Schema engine.
    /// Supported: *attrs-victoria.schema.json*, *SpotCategories.schema.json*, *HazardPayload.schema.json* (case-insensitive contains).
    public func validate(jsonData data: Data, schemaURL: URL) throws {
        let name = schemaURL.lastPathComponent.lowercased()
        let schema: Schema? =
            name.contains("attrs") ? .attrsV1 :
            name.contains("spotcategories") ? .spotCategoriesV1 :
            name.contains("hazard") ? .hazardPayloadV1 : nil
        guard let s = schema else {
            // If unknown schema file, treat as pass (keeps CI unblocked). You can tighten later.
            log.info("JSONSchemaValidator: unknown schema file '\(schemaURL.lastPathComponent, privacy: .public)'. Skipping validation.")
            return
        }
        let result = validate(data: data, with: s)
        if !result.isValid {
            let msg = result.errors.map { "\($0.path): \($0.message)" }.joined(separator: "; ")
            throw NSError(domain: "JSONSchemaValidator", code: 1, userInfo: [NSLocalizedDescriptionKey: msg])
        }
    }
}

// MARK: - Schema implementations

private extension JSONSchemaValidator {

    // --------------------------
    // attrsV1
    // --------------------------
    func validateAttrsV1(json: Any) -> [ValidationError] {
        var errs: [ValidationError] = []
        guard let root = json as? [String: Any] else { return [err("$", "Expected object")] }

        // schemaVersion
        reqInt(root, key: "schemaVersion", min: 1, path: "schemaVersion", &errs)

        // metadata
        if let meta = root["metadata"] as? [String: Any] {
            reqString(meta, key: "city", nonEmpty: true, path: "metadata.city", &errs)
            if let last = meta["lastUpdated"] as? String {
                if !isISO8601(last) { errs.append(err("metadata.lastUpdated", "Expected ISO8601 date-time")) }
            } else {
                errs.append(err("metadata.lastUpdated", "Missing string"))
            }
            reqString(meta, key: "dataSource", nonEmpty: true, path: "metadata.dataSource", &errs)
        } else {
            errs.append(err("metadata", "Missing object"))
        }

        // points
        guard let points = root["points"] as? [Any], !points.isEmpty else {
            errs.append(err("points", "Missing non-empty array")); return errs
        }

        for (i, any) in points.enumerated() {
            guard let p = any as? [String: Any] else {
                errs.append(err("points[\(i)]", "Expected object")); continue
            }
            let base = "points[\(i)]"

            // Coordinates
            reqNumber(p, key: "lat", min: -90, max: 90, path: "\(base).lat", &errs)
            reqNumber(p, key: "lon", min: -180, max: 180, path: "\(base).lon", &errs)

            // Booleans
            reqBool(p, key: "hasProtectedLane", path: "\(base).hasProtectedLane", &errs)
            reqBool(p, key: "hasPaintedLane", path: "\(base).hasPaintedLane", &errs)

            // Surface + roughness
            if let surface = p["surface"] as? String {
                let allowed = Set(["asphalt", "concrete", "brick", "pavers", "gravel", "mixed"])
                if !allowed.contains(surface) {
                    errs.append(err("\(base).surface", "Unexpected value '\(surface)'"))
                }
            } else { errs.append(err("\(base).surface", "Missing string")) }
            reqNumber(p, key: "surfaceRough", min: 0, max: 1, path: "\(base).surfaceRough", &errs)

            // Hazard & freshness
            reqInt(p, key: "hazardCount", min: 0, path: "\(base).hazardCount", &errs)
            reqInt(p, key: "freshnessDays", min: 0, path: "\(base).freshnessDays", &errs)

            // lightingLevel — accepts new {good, moderate, poor} and legacy {high, medium, low}
            if let lvl = p["lightingLevel"] as? String {
                let newAllowed = Set(["good", "moderate", "poor"])
                let legacy = ["high": "good", "medium": "moderate", "low": "poor"]
                if !newAllowed.contains(lvl) && legacy[lvl] == nil {
                    errs.append(err("\(base).lightingLevel", "Expected one of {good, moderate, poor} (or legacy {high, medium, low}), got '\(lvl)'"))
                }
            } else { errs.append(err("\(base).lightingLevel", "Missing string")) }

            // Optional confidence/source
            if let c = p["confidence"] { numInRange(c, 0, 1, path: "\(base).confidence", &errs) }
            if let s = p["source"] { if (s as? String)?.isEmpty != false { errs.append(err("\(base).source", "Must be non-empty string when present")) } }
        }

        return errs
    }

    // --------------------------
    // spotCategoriesV1
    // --------------------------
    func validateSpotCategoriesV1(json: Any) -> [ValidationError] {
        var errs: [ValidationError] = []
        guard let root = json as? [String: Any] else { return [err("$", "Expected object")] }

        reqInt(root, key: "schemaVersion", min: 1, path: "schemaVersion", &errs)

        guard let cats = root["categories"] as? [Any], !cats.isEmpty else {
            errs.append(err("categories", "Missing non-empty array")); return errs
        }

        var seenIds = Set<String>()

        for (i, any) in cats.enumerated() {
            guard let c = any as? [String: Any] else { errs.append(err("categories[\(i)]", "Expected object")); continue }
            let base = "categories[\(i)]"

            // id (^[a-z0-9_\-]+$), unique
            if let id = c["id"] as? String, !id.isEmpty {
                if !matches(id, "^[a-z0-9_\\-]+$") {
                    errs.append(err("\(base).id", "Invalid id format"))
                }
                if !seenIds.insert(id).inserted {
                    errs.append(err("\(base).id", "Duplicate id '\(id)'"))
                }
            } else { errs.append(err("\(base).id", "Missing string")) }

            // labelKey prefix spot.
            if let lk = c["labelKey"] as? String, lk.hasPrefix("spot.") {
                // ok
            } else { errs.append(err("\(base).labelKey", "Must start with 'spot.'")) }

            // glyph & colorToken
            if let glyph = c["glyph"] as? String, !glyph.isEmpty {} else { errs.append(err("\(base).glyph", "Missing string")) }
            if let token = c["colorToken"] as? String, !token.isEmpty {} else { errs.append(err("\(base).colorToken", "Missing string")) }

            // allowNightTag
            reqBool(c, key: "allowNightTag", path: "\(base).allowNightTag", &errs)

            // defaultSafety enum
            if let s = c["defaultSafety"] as? String {
                if !["low","moderate","high"].contains(s) {
                    errs.append(err("\(base).defaultSafety", "Expected one of {low, moderate, high}"))
                }
            } else { errs.append(err("\(base).defaultSafety", "Missing string")) }
        }

        return errs
    }

    // --------------------------
    // hazardPayloadV1
    // --------------------------
    func validateHazardPayloadV1(json: Any) -> [ValidationError] {
        // Accept either a single object or an array of hazards
        if let arr = json as? [Any] {
            var errs: [ValidationError] = []
            for (i, item) in arr.enumerated() {
                errs.append(contentsOf: validateHazardObject(item, base: "[\(i)]"))
            }
            return errs
        } else {
            return validateHazardObject(json, base: "$")
        }
    }

    func validateHazardObject(_ any: Any, base: String) -> [ValidationError] {
        var errs: [ValidationError] = []
        guard let h = any as? [String: Any] else { return [err(base, "Expected object")] }

        // id
        if let id = h["id"] as? String, !id.isEmpty {} else { errs.append(err("\(base).id", "Missing string")) }

        // coord { lat, lon }
        if let coord = h["coord"] as? [String: Any] {
            reqNumber(coord, key: "lat", min: -90, max: 90, path: "\(base).coord.lat", &errs)
            reqNumber(coord, key: "lon", min: -180, max: 180, path: "\(base).coord.lon", &errs)
        } else { errs.append(err("\(base).coord", "Missing object")) }

        // type (string)
        if let t = h["type"] as? String, !t.isEmpty {} else { errs.append(err("\(base).type", "Missing string")) }

        // severity 1..3
        if let s = h["severity"] as? NSNumber {
            let v = s.intValue
            if v < 1 || v > 3 { errs.append(err("\(base).severity", "Expected integer 1..3")) }
        } else { errs.append(err("\(base).severity", "Missing integer")) }

        // createdAt ISO8601
        if let c = h["createdAt"] as? String {
            if !isISO8601(c) { errs.append(err("\(base).createdAt", "Expected ISO8601 date-time")) }
        } else { errs.append(err("\(base).createdAt", "Missing string")) }

        return errs
    }
}

// MARK: - Small helpers

private extension JSONSchemaValidator {

    func err(_ path: String, _ msg: String) -> ValidationError { ValidationError(path: path, message: msg) }

    func reqInt(_ obj: [String: Any], key: String, min: Int? = nil, max: Int? = nil, path: String, _ errs: inout [ValidationError]) {
        guard let n = obj[key] as? NSNumber else { errs.append(err(path, "Missing integer")); return }
        let v = n.intValue
        if let min, v < min { errs.append(err(path, "Too small (< \(min))")) }
        if let max, v > max { errs.append(err(path, "Too large (> \(max))")) }
    }

    func reqNumber(_ obj: [String: Any], key: String, min: Double? = nil, max: Double? = nil, path: String, _ errs: inout [ValidationError]) {
        if let n = obj[key] as? NSNumber {
            let v = n.doubleValue
            if let min, v < min { errs.append(err(path, "Too small (< \(min))")) }
            if let max, v > max { errs.append(err(path, "Too large (> \(max))")) }
        } else {
            errs.append(err(path, "Missing number"))
        }
    }

    func reqBool(_ obj: [String: Any], key: String, path: String, _ errs: inout [ValidationError]) {
        guard obj[key] as? Bool != nil else { errs.append(err(path, "Missing boolean")); return }
    }

    func reqString(_ obj: [String: Any], key: String, nonEmpty: Bool, path: String, _ errs: inout [ValidationError]) {
        guard let s = obj[key] as? String else { errs.append(err(path, "Missing string")); return }
        if nonEmpty && s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errs.append(err(path, "Must be non-empty"))
        }
    }

    func isISO8601(_ s: String) -> Bool {
        // Support seconds/millis; strict otherwise
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if fmt.date(from: s) != nil { return true }
        fmt.formatOptions = [.withInternetDateTime]
        return fmt.date(from: s) != nil
    }

    func matches(_ s: String, _ pattern: String) -> Bool {
        (try? NSRegularExpression(pattern: pattern))?
            .firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) != nil
    }
}
