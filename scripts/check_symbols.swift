#!/usr/bin/env swift
// Scan Swift sources for SF Symbol names and report ones unavailable on this OS.
// Usage: swift scripts/check_symbols.swift app/Sources [more dirs...]

import AppKit
import Foundation

let args = Array(CommandLine.arguments.dropFirst())
guard !args.isEmpty else {
    FileHandle.standardError.write("usage: check_symbols.swift <dir> [dir...]\n".data(using: .utf8)!)
    exit(2)
}

var names = Set<String>()
let namePattern = try! NSRegularExpression(pattern: "(?:systemImage|systemName)\\s*:\\s*\"([^\"]+)\"")
let imagePattern = try! NSRegularExpression(pattern: "Image\\(systemName:\\s*\"([^\"]+)\"")

func scan(_ url: URL) {
    guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil) else { return }
    for case let file as URL in enumerator where file.pathExtension == "swift" {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
        let range = NSRange(text.startIndex..., in: text)
        for regex in [namePattern, imagePattern] {
            for match in regex.matches(in: text, range: range) {
                if let r = Range(match.range(at: 1), in: text) {
                    names.insert(String(text[r]))
                }
            }
        }
    }
}

for arg in args {
    scan(URL(fileURLWithPath: arg))
}

var missing: [String] = []
var checked = 0
for name in names.sorted() {
    checked += 1
    let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
    if image == nil {
        missing.append(name)
    }
}

print("checked \(checked) symbol names")
if missing.isEmpty {
    print("OK: all symbols available")
} else {
    print("MISSING (\(missing.count)):")
    for name in missing { print("  - \(name)") }
    exit(1)
}
