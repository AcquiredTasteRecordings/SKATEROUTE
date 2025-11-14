// Support/Moderation/BannedTermsCatalog.swift
// Centralized source for SkateRoute's banned term lists with locale-aware lookup.
// Lists derived from curated moderation datasets (see docs/ModerationBannedTerms.md).

import Foundation

public enum BannedTermsCatalog {
    private static let fallbackLocaleIdentifier = "en"

    private static let catalogs: [String: [String]] = [
        "en": Self.makeList([
            "antisemitic",
            "antiziganist",
            "chink",
            "coon",
            "dyke",
            "faggot",
            "golliwog",
            "gook",
            "gyppo",
            "jap",
            "kike",
            "kkk",
            "mongoloid",
            "nazi",
            "negro",
            "nigger",
            "paki",
            "porchmonkey",
            "raghead",
            "spic",
            "tranny",
            "wetback"
        ]),
        "es": Self.makeList([
            "cabron",
            "cerdo",
            "chingada",
            "chingar",
            "gilipollas",
            "hijo de puta",
            "malparido",
            "marica",
            "maricon",
            "mierda",
            "pendejo",
            "perra",
            "puta",
            "puto",
            "zorra"
        ]),
        "fr": Self.makeList([
            "batard",
            "bougnoule",
            "con",
            "encule",
            "fils de pute",
            "gouine",
            "nique ta mere",
            "nique ta race",
            "pd",
            "pute",
            "salope",
            "youpin"
        ])
    ]

    public static func terms(for locale: Locale = .current) -> [String] {
        let identifiers = localeIdentifiers(for: locale)
        for identifier in identifiers {
            if let list = catalogs[identifier] { return list }
        }
        if let fallback = catalogs[fallbackLocaleIdentifier] { return fallback }
        return []
    }

    private static func localeIdentifiers(for locale: Locale) -> [String] {
        var identifiers: [String] = []
        let normalized = locale.identifier
            .replacingOccurrences(of: "-", with: "_")
            .lowercased()
        if !normalized.isEmpty {
            identifiers.append(normalized)
        }
        if let languageCode = locale.languageCode?.lowercased() {
            identifiers.append(languageCode)
        } else if let first = normalized.split(separator: "_").first {
            identifiers.append(String(first))
        }
        identifiers.append(fallbackLocaleIdentifier)
        var seen = Set<String>()
        return identifiers.compactMap { identifier in
            guard !identifier.isEmpty, !seen.contains(identifier) else { return nil }
            seen.insert(identifier)
            return identifier
        }
    }

    private static func makeList(_ terms: [String]) -> [String] {
        var seen = Set<String>()
        var cleaned: [String] = []
        for raw in terms {
            let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !normalized.isEmpty, !seen.contains(normalized) else { continue }
            seen.insert(normalized)
            cleaned.append(normalized)
        }
        return cleaned
    }
}
