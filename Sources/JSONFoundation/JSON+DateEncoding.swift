//
//  JSON+DateEncoding.swift
//  JSONFoundation
//
//  Created by Oliver Drobnik on 07.04.25.
//

import Foundation

/// Builds the ISO 8601 formatter shared by the `iso8601WithTimeZone` encoding
/// and decoding strategies.
///
/// A fresh instance is built per call: `ISO8601DateFormatter`'s thread safety
/// is not guaranteed on non-Apple Foundation, and constructing lazily re-reads
/// `TimeZone.current` in case the host's time zone changed.
private func makeISO8601Formatter(
    formatOptions: ISO8601DateFormatter.Options = [.withInternetDateTime, .withTimeZone]
) -> ISO8601DateFormatter {
    let formatter = ISO8601DateFormatter()
    formatter.timeZone = TimeZone.current
    formatter.formatOptions = formatOptions
    return formatter
}

extension JSONEncoder.DateEncodingStrategy {
    /// Encodes a `Date` as an ISO 8601 string with an explicit UTC offset,
    /// e.g. `2025-04-07T14:00:00+02:00`. Sub-second precision is not encoded.
    ///
    /// The offset is the host machine's *current* time zone, so the encoded
    /// string for the same `Date` varies by machine — including in the
    /// otherwise-deterministic ``JSONCoding/makeWireEncoder()`` output.
    public static let iso8601WithTimeZone = JSONEncoder.DateEncodingStrategy.custom { date, encoder in
        let string = makeISO8601Formatter().string(from: date)
        var container = encoder.singleValueContainer()
        try container.encode(string)
    }
}

extension JSONDecoder.DateDecodingStrategy {
    /// Decodes an ISO 8601 string carrying a time-zone offset — the
    /// counterpart of `JSONEncoder.DateEncodingStrategy.iso8601WithTimeZone`.
    /// Accepts whole-second and fractional-second timestamps; anything else
    /// throws `DecodingError.dataCorrupted`.
    public static let iso8601WithTimeZone = JSONDecoder.DateDecodingStrategy.custom { decoder in
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        if let date = makeISO8601Formatter().date(from: string) {
            return date
        }
        // Common producers include fractional seconds, which the default
        // options reject; retry with them before giving up.
        let fractional: ISO8601DateFormatter.Options = [.withInternetDateTime, .withTimeZone, .withFractionalSeconds]
        if let date = makeISO8601Formatter(formatOptions: fractional).date(from: string) {
            return date
        }
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid ISO 8601 date")
    }
}
