//
//  String+Documentation.swift
//  JSONFoundationMacros
//

import Foundation

extension String {
    var removingUnprintableCharacters: String {
        // Drop only actual control characters (category Cc), keeping whitespace
        // controls. Deliberately not CharacterSet.controlCharacters, which also
        // covers format characters (Cf) like the ZWJ that emoji sequences need.
        // Non-ASCII text (umlauts, accents, emoji) passes through untouched.
        var scalars = String.UnicodeScalarView()
        for scalar in unicodeScalars
        where scalar.properties.generalCategory != .control || scalar == "\t" || scalar == "\n" || scalar == "\r" {
            scalars.append(scalar)
        }
        return String(scalars)
    }

    /// Escapes a string for use in a Swift string literal.
    /// This handles quotes, backslashes, and other special characters.
    var escapedForSwiftString: String {
        return self
            .replacingOccurrences(of: "\\", with: "\\\\") // Escape backslashes first
            .replacingOccurrences(of: "\"", with: "\\\"") // Escape double quotes
            .replacingOccurrences(of: "\'", with: "\\\'") // Escape single quotes
            .replacingOccurrences(of: "\n", with: "\\n") // Escape newlines
            .replacingOccurrences(of: "\r", with: "\\r") // Escape carriage returns
            .replacingOccurrences(of: "\t", with: "\\t") // Escape tabs
            .replacingOccurrences(of: "\0", with: "\\0") // Escape null bytes
    }
}
