//
//  Documentation.swift
//  JSONFoundationMacros
//
//  Parses a leading-trivia doc-comment block into the plain-text description
//  `@Schema` emits for structs and properties. Dash-prefixed section markers
//  (`- Parameter …`, `- Returns: …`, `- Note: …`) end the description; the
//  sections themselves carry no schema-relevant content and are discarded.
//

import Foundation

struct Documentation {
    /// The doc comment's initial (multi-line) description, up to the first
    /// dash-prefixed section marker.
    let description: String

    init(from text: String) {
        let cleanedLines = Self.cleanDocumentationLines(from: text)
        self.description = Self.combineLines(Self.descriptionLines(from: cleanedLines))
    }

    // MARK: - Line cleaning

    /// Removes comment markers and extra whitespace from each line, leaving
    /// only the textual content of the documentation.
    private static func cleanDocumentationLines(from text: String) -> [String] {
        let lines = text.components(separatedBy: .newlines)
        var cleanedLines = [String]()
        var previousLineWasEmpty = false
        var inDocumentationBlock = false

        for var line in lines {
            line = line.trimmingCharacters(in: .whitespaces)

            if line.isEmpty && !inDocumentationBlock {
                continue
            }

            let cleanResult = cleanLine(line, inDocumentationBlock: &inDocumentationBlock)
            guard cleanResult.shouldProcess else { continue }
            line = cleanResult.line

            if inDocumentationBlock && line.hasPrefix("*") {
                line = line.dropFirst().trimmingCharacters(in: .whitespaces)
            }

            line = line.removingUnprintableCharacters

            // For single-line documentation blocks with parameters, split into multiple lines
            if cleanResult.isDocumentationLine && line.contains(" - Parameter ") {
                if appendSplitParameters(line: line, into: &cleanedLines) {
                    continue
                }
            }

            if line.isEmpty {
                if !previousLineWasEmpty {
                    cleanedLines.append(line)
                }
            } else {
                cleanedLines.append(line)
            }
            previousLineWasEmpty = line.isEmpty

            if line.hasSuffix("*/") {
                inDocumentationBlock = false
            }
        }

        return cleanedLines
    }

    private struct CleanLineResult {
        var line: String
        var shouldProcess: Bool
        var isDocumentationLine: Bool
    }

    /// Strips comment markers (`///`, `/**`, `*/`) from a single line, updating
    /// the multi-line block flag as appropriate.
    private static func cleanLine(_ raw: String, inDocumentationBlock: inout Bool) -> CleanLineResult {
        var line = raw
        if line.hasPrefix("/**") {
            inDocumentationBlock = true
            line = line.replacingOccurrences(of: "/**", with: "")
            if line.hasSuffix("*/") {
                line = String(line.dropLast(2)).trimmingCharacters(in: .whitespaces)
            }
            return CleanLineResult(line: line, shouldProcess: true, isDocumentationLine: true)
        }
        if line.hasSuffix("*/") {
            line = String(line.dropLast(2)).trimmingCharacters(in: .whitespaces)
            let wasInBlock = inDocumentationBlock
            inDocumentationBlock = false
            return CleanLineResult(line: line, shouldProcess: wasInBlock, isDocumentationLine: wasInBlock)
        }
        if line.hasPrefix("///") {
            line = line.dropFirst(3).trimmingCharacters(in: .whitespaces)
            return CleanLineResult(line: line, shouldProcess: true, isDocumentationLine: true)
        }
        return CleanLineResult(
            line: line,
            shouldProcess: inDocumentationBlock,
            isDocumentationLine: inDocumentationBlock
        )
    }

    /// Splits a single-line block that contains multiple inline `- Parameter`
    /// entries into separate lines, so the leading description text can be
    /// isolated from them. Returns true if a split occurred and the caller
    /// should skip default appending.
    private static func appendSplitParameters(line: String, into cleanedLines: inout [String]) -> Bool {
        let parts = line.components(separatedBy: " - Parameter ")
        guard parts.count > 1 else { return false }
        cleanedLines.append(parts[0].trimmingCharacters(in: .whitespaces))
        for paramPart in parts.dropFirst() {
            cleanedLines.append("- Parameter " + paramPart.trimmingCharacters(in: .whitespaces))
        }
        return true
    }

    // MARK: - Section filtering

    /// Returns the lines that make up the description: everything up to the
    /// first dash-prefixed line. `- Parameter …`, `- Returns: …`, and any
    /// other `- Section:` marker start structured sections that never feed
    /// back into the description.
    private static func descriptionLines(from cleanedLines: [String]) -> [String] {
        Array(cleanedLines.prefix { !$0.hasPrefix("-") })
    }

    // MARK: - Combining

    /// Joins a list of lines into a single string, collapsing consecutive
    /// empty lines into paragraph breaks.
    private static func combineLines(_ lines: [String]) -> String {
        var combined = ""
        var previousLineWasEmpty = false
        for line in lines {
            if line.isEmpty {
                if !previousLineWasEmpty {
                    combined += "\n\n"
                }
            } else {
                if !combined.isEmpty && !previousLineWasEmpty {
                    combined += " "
                }
                combined += line
            }
            previousLineWasEmpty = line.isEmpty
        }
        return combined.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
