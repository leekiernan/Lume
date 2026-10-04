#!/usr/bin/env swift
import Foundation

// Checks String Catalog (.xcstrings) files for missing or untranslated strings.
//
// Exits non-zero if any language is missing translations, so it can be wired
// into CI or a pre-commit hook.
//
// Usage:
//   swift Scripts/check-translations.swift                         # checks Lume/Localizable.xcstrings
//   swift Scripts/check-translations.swift path/to/File.xcstrings  # explicit file(s)

let paths: [String] = CommandLine.arguments.count > 1
    ? Array(CommandLine.arguments.dropFirst())
    : ["Lume/Localizable.xcstrings"]

var failed = false

/// Catalog entries may contain plural/device variants rather than a flat
/// stringUnit. Check their leaves instead of misreporting them as untranslated.
func stringUnits(in node: [String: Any]) -> [[String: Any]] {
    let own = (node["stringUnit"] as? [String: Any]).map { [$0] } ?? []
    let children = node.filter { $0.key != "stringUnit" }.values.compactMap { $0 as? [String: Any] }
    return own + children.flatMap { stringUnits(in: $0) }
}

for path in paths {
    let url = URL(fileURLWithPath: path)
    guard let data = try? Data(contentsOf: url),
          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let strings = root["strings"] as? [String: Any],
          let sourceLanguage = root["sourceLanguage"] as? String
    else {
        fputs("error: \(path): could not parse as .xcstrings JSON\n", stderr)
        failed = true
        continue
    }

    // Collect all languages present in the file
    var allLanguages = Set<String>()
    for (_, value) in strings {
        guard let entry = value as? [String: Any],
              let localizations = entry["localizations"] as? [String: Any]
        else { continue }
        allLanguages.formUnion(localizations.keys)
    }
    allLanguages.remove(sourceLanguage)

    var missingByLanguage: [String: [String]] = [:]
    var newStateByLanguage: [String: [String]] = [:]

    for (key, value) in strings {
        // Empty/punctuation-only fragments have no linguistic translation.
        guard key.rangeOfCharacter(from: .letters) != nil else { continue }
        guard let entry = value as? [String: Any] else { continue }
        guard entry["extractionState"] as? String != "stale" else { continue }
        let localizations = entry["localizations"] as? [String: Any] ?? [:]

        for language in allLanguages {
            guard let locEntry = localizations[language] as? [String: Any],
                  !stringUnits(in: locEntry).isEmpty,
                  stringUnits(in: locEntry).allSatisfy({ ($0["value"] as? String)?.isEmpty == false })
            else {
                missingByLanguage[language, default: []].append(key)
                continue
            }
            if stringUnits(in: locEntry).contains(where: { ["new", "needs_review"].contains($0["state"] as? String ?? "") }) {
                newStateByLanguage[language, default: []].append(key)
            }
        }
    }

    var fileHadIssues = false

    for language in allLanguages.sorted() {
        let missing = missingByLanguage[language]?.sorted() ?? []
        let needsReview = newStateByLanguage[language]?.sorted() ?? []

        if !missing.isEmpty {
            print("\n\(path) [\(language)] — \(missing.count) missing translation(s):")
            for key in missing {
                print("  \(key)")
            }
            fileHadIssues = true
            failed = true
        }

        if !needsReview.isEmpty {
            print("\n\(path) [\(language)] — \(needsReview.count) string(s) marked 'new' or 'needs_review':")
            for key in needsReview {
                print("  \(key)")
            }
        }
    }

    if !fileHadIssues {
        let reviewCount = newStateByLanguage.values.flatMap(\.self).count
        if reviewCount > 0 {
            print("\(path): OK (no missing translations; \(reviewCount) marked for review)")
        } else {
            print("\(path): OK")
        }
    }
}

exit(failed ? 1 : 0)
