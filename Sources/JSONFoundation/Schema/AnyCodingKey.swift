import Foundation

/**
 A coding key that can be initialized with any string value.
 Used for encoding and decoding dynamic property names in JSON schemas.
 */
public struct AnyCodingKey: CodingKey {
    /// The string value of the coding key
    public var stringValue: String
    /// The integer value of the coding key, if any
    public var intValue: Int?

    /**
     Creates a coding key from a string value (always succeeds).

     The non-failable counterpart to ``init(stringValue:)`` — convenient when the
     key is known to be a plain string, e.g. a tagged-union discriminator.

     - Parameter stringValue: The string value for the key
     */
    public init(_ stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    /**
     Creates a coding key from a string value.

     - Parameter stringValue: The string value for the key
     - Returns: A coding key, or nil if the string value is invalid
     */
    public init?(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }

    /**
     Creates a coding key from an integer value.

     - Parameter intValue: The integer value for the key
     - Returns: A coding key, or nil if the integer value is invalid
     */
    public init?(intValue: Int) {
        self.stringValue = String(intValue)
        self.intValue = intValue
    }
}
