#!/usr/bin/env swift
import Foundation

// Regression fixtures for the command-line catalog checker, independent of
// the app/simulator. The generated files and child processes are task-local.
// Usage: swift Scripts/test-check-translations.swift (from the repo root).
let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lume-translations-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: directory) }

func unit(_ value: String, state: String = "translated") -> [String: Any] {
    ["stringUnit": ["state": state, "value": value]]
}

func check(_ name: String, entry: [String: Any], expectedExit: Int32, outputContains: String) throws {
    let reference: [String: Any] = ["localizations": ["de": unit("Referenz")]]
    let catalog: [String: Any] = ["sourceLanguage": "en", "strings": ["Reference": reference, name: entry]]
    let file = directory.appendingPathComponent("\(UUID().uuidString).xcstrings")
    try JSONSerialization.data(withJSONObject: catalog).write(to: file)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["swift", "Scripts/check-translations.swift", file.path]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let output = String(data: data, encoding: .utf8) ?? ""
    guard process.terminationStatus == expectedExit, output.contains(outputContains) else {
        fatalError("\(name): expected exit \(expectedExit), got \(process.terminationStatus): \(output)")
    }
    print("PASS: \(name)")
}

try check("Flat", entry: ["localizations": ["de": unit("Text")]], expectedExit: 0, outputContains: ": OK")
try check("Plural", entry: ["localizations": ["de": ["variations": ["plural": ["one": unit("Ein Element"), "other": unit("Elemente")]]]]], expectedExit: 0, outputContains: ": OK")
try check("Empty plural leaf", entry: ["localizations": ["de": ["variations": ["plural": ["one": unit("Ein Element"), "other": unit("")]]]]], expectedExit: 1, outputContains: "missing translation")
let substitution: [String: Any] = [
    "localizations": ["de": [
        "stringUnit": ["state": "translated", "value": "%#@items@"],
        "substitutions": ["items": ["variations": ["plural": ["other": unit("")]]]]
    ]]
]
try check("Substitution", entry: substitution, expectedExit: 1, outputContains: "missing translation")
try check("Missing language", entry: ["localizations": [:]], expectedExit: 1, outputContains: "missing translation")
try check("Stale", entry: ["extractionState": "stale"], expectedExit: 0, outputContains: ": OK")
try check(", ", entry: [:], expectedExit: 0, outputContains: ": OK")
try check("", entry: [:], expectedExit: 0, outputContains: ": OK")
try check("Needs review", entry: ["localizations": ["de": unit("Text", state: "needs_review")]], expectedExit: 0, outputContains: "marked for review")
