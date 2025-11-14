# Banned Term Provenance & Localization

This document tracks the source datasets, review process, and localization notes for the
client-side banned term list referenced from `Policy.UGC.bannedTerms`.

## Source Datasets

* **LDNOOBW — List of Dirty, Naughty, Obscene, and Otherwise Bad Words**
  * Repository: https://github.com/LDNOOBW/List-of-Dirty-Naughty-Obscene-and-Otherwise-Bad-Words
  * Snapshot: commit `5d40c564be8c1ab0b7d14318e403d315f6d10f36` (2024-11-02)
  * License: Creative Commons Attribution 4.0
* **Web-mech badwords (English focus)**
  * Repository: https://github.com/web-mech/badwords
  * Snapshot: commit `b8aa8165d8e2620d6dbe85e8fb8d4288f62cb14f` (2024-10-17)

The on-device list is a curated subset focused on high-severity hateful and harassing
terms. Entries targeting protected classes take precedence. Each locale list is capped at
~25 entries to keep the binary size small; server-side moderation enforces a broader
superset.

## Localization Workflow

1. Start from the English LDNOOBW list; flag the highest severity hateful slurs.
2. For Spanish and French, cross-reference the locale-specific LDNOOBW lists.
3. Remove duplicates, normalize accents to the canonical forms we expect from user input,
   and convert to lowercase for consistent comparisons.
4. Submit the candidate list to the localization review queue (L10N-2045) for
   confirmation that each term reflects contemporary usage.
5. Incorporate reviewer feedback. (Nov 2024 batch approved by Javier Núñez for ES and
   Clémence Giraud for FR.)
6. Update `BannedTermsCatalog.catalogs` with the final per-locale arrays.

## Update Procedure

* Re-run the selection process above, capturing the commit hashes of any source datasets.
* Coordinate with localization (L10N queue) for validation on every new term.
* Add or adjust locale arrays inside `Support/Moderation/BannedTermsCatalog.swift`.
* Extend `BannedTermsCatalog.catalogs` when new locales come online.
* Add or update XCTest coverage in `SKATEROUTETests/BannedTermsCatalogTests.swift` to
  verify that every locale we claim to support loads a non-empty list.
* Reference this document in the PR summary so reviewers can double-check provenance.
