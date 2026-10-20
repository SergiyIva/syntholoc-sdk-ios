import Foundation

/// Unicode CLDR 47 cardinal rules, including visible decimal operands.
/// Rules are packaged data, never downloaded executable expressions.
public enum OtaPluralRules {
  private struct Relation {
    let operand: String
    let modulus: Decimal?
    let different: Bool
    let ranges: [ClosedRange<Decimal>]
    func matches(_ operands: [String: Decimal]) -> Bool {
      var value = operands[operand] ?? 0
      if let modulus = modulus { value -= floor(value / modulus) * modulus }
      let member = value == floor(value) && ranges.contains { $0.contains(value) }
      return different ? !member : member
    }
  }
  private static func floor(_ value: Decimal) -> Decimal {
    var value = value
    var rounded = Decimal()
    NSDecimalRound(&rounded, &value, 0, .down)
    return rounded
  }
  private static let root = Dictionary(
    uniqueKeysWithValues: PackagedPluralRules.cardinal.map { ($0.key.lowercased(), $0.value) })
  static func validatePackagedRules() throws {
    try Wire.require(root.count > 150)
    for rules in root.values {
      for (category, expression) in rules where category != "pluralRule-count-other" {
        _ = try parse(expression)
      }
    }
  }
  private static func parse(_ source: String) throws -> [[Relation]] {
    let expression = String(source.split(separator: "@", maxSplits: 1).first ?? "")
      .trimmingCharacters(in: .whitespaces)
    let regex = try NSRegularExpression(
      pattern: "^([nivwftec])(?: % ([0-9]+))? (!=|=) ([0-9., ]+)$")
    return try expression.components(separatedBy: " or ").map { part in
      try part.components(separatedBy: " and ").map { clause in
        let ns = clause as NSString
        guard
          let match = regex.firstMatch(in: clause, range: NSRange(location: 0, length: ns.length))
        else { throw OtaFailure.invalidManifest }
        func group(_ index: Int) -> String {
          let range = match.range(at: index)
          return range.location == NSNotFound ? "" : ns.substring(with: range)
        }
        let modulus = Decimal(string: group(2), locale: Locale(identifier: "en_US_POSIX"))
        let ranges = try group(4).components(separatedBy: ",").map {
          range -> ClosedRange<Decimal> in
          let parts = range.trimmingCharacters(in: .whitespaces).components(separatedBy: "..")
          guard let lower = Decimal(string: parts[0]), let upper = Decimal(string: parts.last!),
            lower <= upper
          else { throw OtaFailure.invalidManifest }
          return lower...upper
        }
        return Relation(
          operand: group(1), modulus: modulus, different: group(3) == "!=", ranges: ranges)
      }
    }
  }
  public static func category(decimal: String, languageTag: String) throws -> String {
    guard Wire.matches(decimal, "^-?[0-9]{1,20}(\\.[0-9]{1,18})?$") else {
      throw OtaFailure.incompatible
    }
    let text = decimal.hasPrefix("-") ? String(decimal.dropFirst()) : decimal
    let parts = text.split(separator: ".", omittingEmptySubsequences: false)
    let fraction = parts.count == 2 ? String(parts[1]) : ""
    let trimmed = String(fraction.reversed().drop(while: { $0 == "0" }).reversed())
    guard let n = Decimal(string: text), let i = Decimal(string: String(parts[0])) else {
      throw OtaFailure.incompatible
    }
    let operands: [String: Decimal] = [
      "n": n, "i": i, "v": Decimal(fraction.count), "w": Decimal(trimmed.count),
      "f": Decimal(string: fraction) ?? 0, "t": Decimal(string: trimmed) ?? 0, "e": 0, "c": 0,
    ]
    let tag = languageTag.replacingOccurrences(of: "_", with: "-").lowercased()
    let locale = tag.split(separator: "-").first.map(String.init) ?? tag
    let rules = root[tag] ?? root[locale] ?? [:]
    for category in ["zero", "one", "two", "few", "many"] {
      guard let source = rules["pluralRule-count-\(category)"] else { continue }
      if try parse(source).contains(where: { $0.allSatisfy { $0.matches(operands) } }) {
        return category
      }
    }
    return "other"
  }
}
