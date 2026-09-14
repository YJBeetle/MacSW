import Foundation

public enum SerialNumberService {
    private static let serialPattern = #"(?i)(?<![A-Z0-9])[A-Z0-9]{4}(?:[\s-]+[A-Z0-9]{4}){5}(?![A-Z0-9])"#

    public static func parse(_ text: String) throws -> ParsedSerialNumbers {
        let headingAlternatives = SolidWorksProduct.longestNamesFirst
            .map { NSRegularExpression.escapedPattern(for: $0.rawValue) }
            .joined(separator: "|")
        let headingExpression = try NSRegularExpression(
            pattern: "(?im)^\\s*(\(headingAlternatives))\\s*(?::|=)?\\s*",
            options: [.caseInsensitive, .anchorsMatchLines]
        )
        let serialExpression = try NSRegularExpression(pattern: serialPattern)
        let fullRange = NSRange(text.startIndex..., in: text)
        let headings = headingExpression.matches(in: text, range: fullRange)

        if headings.isEmpty {
            let serials = uniqueSerials(in: text, expression: serialExpression)
            guard !serials.isEmpty else { throw SerialNumberError.noSerialNumber }
            guard serials.count == 1 else { throw SerialNumberError.multipleUnlabelledSerialNumbers }
            return ParsedSerialNumbers(values: [.solidWorks: serials[0]])
        }

        var parsed: [SolidWorksProduct: String] = [:]
        for (index, heading) in headings.enumerated() {
            guard let titleRange = Range(heading.range(at: 1), in: text),
                  let product = SolidWorksProduct.allCases.first(where: {
                      $0.rawValue.caseInsensitiveCompare(String(text[titleRange])) == .orderedSame
                  }) else { continue }
            let sectionStart = heading.range.location + heading.range.length
            let sectionEnd = index + 1 < headings.count ? headings[index + 1].range.location : fullRange.length
            guard sectionStart <= sectionEnd,
                  let range = Range(NSRange(location: sectionStart, length: sectionEnd - sectionStart), in: text) else { continue }
            let values = uniqueSerials(in: String(text[range]), expression: serialExpression)
            guard !values.isEmpty else { continue }
            guard values.count == 1 else { throw SerialNumberError.conflictingSerialNumbers(product) }
            if let existing = parsed[product], existing != values[0] {
                throw SerialNumberError.conflictingSerialNumbers(product)
            }
            parsed[product] = values[0]
        }
        guard !parsed.isEmpty else { throw SerialNumberError.noSerialNumber }
        return ParsedSerialNumbers(values: parsed)
    }

    public static func registryAssignments(for serials: ParsedSerialNumbers) -> [RegistryAssignment] {
        let serialKey = "HKLM\\SOFTWARE\\SolidWorks\\Licenses\\Serial Numbers"
        var assignments = serials.values
            .map { RegistryAssignment(key: serialKey, name: $0.key.rawValue, value: $0.value) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        if let value = serials.values[.solidWorks] {
            let groups = value.split(separator: " ").map(String.init)
            if groups.count == 6 {
                assignments.append(RegistryAssignment(
                    key: "HKLM\\SOFTWARE\\SolidWorks\\Security",
                    name: "Serial Number",
                    value: groups[0...3].joined(separator: " ")
                ))
                assignments.append(RegistryAssignment(
                    key: "HKLM\\SOFTWARE\\SolidWorks\\Security",
                    name: "Serial Number Extra",
                    value: groups[4...5].joined(separator: " ")
                ))
            }
        }
        return assignments
    }

    private static func uniqueSerials(in text: String, expression: NSRegularExpression) -> [String] {
        let range = NSRange(text.startIndex..., in: text)
        var values: [String] = []
        for match in expression.matches(in: text, range: range) {
            guard let swiftRange = Range(match.range, in: text) else { continue }
            let normalized = text[swiftRange]
                .uppercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            if !values.contains(normalized) { values.append(normalized) }
        }
        return values
    }
}
