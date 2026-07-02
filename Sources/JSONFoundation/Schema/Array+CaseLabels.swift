//
//  Array+CaseLabels.swift
//  JSONFoundation
//
//  Created by Oliver Drobnik on 26.03.25.
//

import Foundation

extension CaseIterable {
    /**
     The labels of all cases of this type, in `allCases` order.

     The labels are extracted using each case's string representation, with special handling
     for cases with associated values: the case name is kept and the associated values are
     trimmed. For example, for a case like `case example(value: Int)`, the label is `"example"`.

     - Note: If the enum conforms to CustomStringConvertible, the case labels are determined
     by the custom description implementation. This allows for customization of how enum cases
     are represented in generated schemas.
     */
    public static var caseLabels: [String] {
        return self.allCases.map { caseValue in
            let description = String(describing: caseValue)

            // trim off associated value if any
            if let parenIndex = description.firstIndex(of: "(") {
                return String(description[..<parenIndex])
            }

            return description
        }
    }
}

extension [String] {
    /**
     Initialize an array of case labels if the given parameter (a type) conforms to CaseIterable.

     - Parameters:
       - type: The type to extract case labels from. Must conform to CaseIterable.

     - Returns: An array of strings containing the case labels, or nil if the type doesn't
       conform to CaseIterable.

     See `CaseIterable.caseLabels` for how the labels are derived.
     */
    @available(*, deprecated, message: "Use `CaseIterable.caseLabels` instead")
    public init?<T>(caseLabelsFrom type: T.Type) {
        // Check if T conforms to CaseIterable at runtime.
        guard let caseIterableType = type as? any CaseIterable.Type else {
            return nil
        }

        self = caseIterableType.caseLabels
    }
}
