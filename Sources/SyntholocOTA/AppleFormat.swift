import Foundation

public enum OtaArgument: Sendable, Equatable {
  case string(String)
  case integer(Int64)
  case number(Double)
  case decimal(String)
  var pluralValue: String? {
    switch self {
    case .integer(let value): return String(value)
    case .number(let value):
      guard value.isFinite, abs(value) < 1e20 else { return nil }
      let formatter = NumberFormatter()
      formatter.locale = Locale(identifier: "en_US_POSIX")
      formatter.numberStyle = .decimal
      formatter.usesGroupingSeparator = false
      formatter.maximumFractionDigits = 18
      return formatter.string(from: NSNumber(value: value))
    case .decimal(let value): return value
    case .string: return nil
    }
  }
}
public enum OtaDevice: String, Sendable {
  case iphone, ipad, mac, applewatch, appletv, applevision, other
}

/// Formats one typed conversion at a time; downloaded %s/%n/pointers and dynamic widths are rejected.
enum AppleFormat {
  static let token = try! NSRegularExpression(
    pattern:
      "%(?:([1-9][0-9]*)\\$)?#@([A-Za-z0-9_]+)@|%%|%(?:([1-9][0-9]*)\\$)?([-+ #0']*)([0-9]{0,3})(?:\\.([0-9]{1,3}))?(hh|ll|h|l|L|z|j|t)?([@diuoxXfFeEgGaAc])"
  )
  static func render(
    _ template: String, arguments: [OtaArgument], languageTag: String, startingAt: Int = 0,
    named: ((String, Int) throws -> (String, Int))? = nil
  ) throws -> (String, Int) {
    guard template.utf8.count <= 65536, arguments.count <= 128 else {
      throw OtaFailure.incompatible
    }
    let source = template as NSString
    var position = 0
    var cursor = startingAt
    var output = ""
    var count = 0
    while position < source.length {
      let search = source.range(
        of: "%", range: NSRange(location: position, length: source.length - position))
      if search.location == NSNotFound {
        output += source.substring(from: position)
        break
      }
      output += source.substring(
        with: NSRange(location: position, length: search.location - position))
      guard
        let match = token.firstMatch(
          in: template, options: .anchored,
          range: NSRange(location: search.location, length: source.length - search.location))
      else { throw OtaFailure.incompatible }
      count += 1
      guard count <= 128 else { throw OtaFailure.incompatible }
      func group(_ index: Int) -> String {
        let range = match.range(at: index)
        return range.location == NSNotFound ? "" : source.substring(with: range)
      }
      let literal = source.substring(with: match.range)
      if literal == "%%" {
        output += "%"
      } else if !group(2).isEmpty {
        let index = (Int(group(1)).map { $0 - 1 }) ?? cursor
        guard let named = named, index >= 0, index < arguments.count else {
          throw OtaFailure.incompatible
        }
        let (text, next) = try named(group(2), index)
        output += text
        cursor = max(cursor, max(index + 1, next))
      } else {
        let index = (Int(group(3)).map { $0 - 1 }) ?? cursor
        guard index >= 0, index < arguments.count else { throw OtaFailure.incompatible }
        cursor = max(cursor, index + 1)
        let flags = group(4)
        let width = group(5)
        let precision = group(6)
        let modifier = group(7)
        let conversion = group(8)
        guard (Int(width) ?? 0) <= 1000, (Int(precision) ?? 0) <= 1000 else {
          throw OtaFailure.incompatible
        }
        let spec =
          "%" + flags + width + (precision.isEmpty ? "" : "." + precision) + modifier + conversion
        let argument = arguments[index]
        let value: CVarArg
        if conversion == "@" {
          guard modifier.isEmpty, case .string(let text) = argument, text.utf8.count <= 1_000_000
          else { throw OtaFailure.incompatible }
          value = text as NSString
        } else if "diuoxXc".contains(conversion) {
          guard case .integer(let number) = argument,
            ["", "h", "hh", "l", "ll", "z", "j", "t"].contains(modifier)
          else { throw OtaFailure.incompatible }
          let unsigned = "uoxX".contains(conversion)
          if unsigned { guard number >= 0 else { throw OtaFailure.incompatible } }
          if ["", "h", "hh"].contains(modifier) {
            let maximum: Int64 =
              modifier == "hh"
              ? (unsigned ? 255 : 127)
              : modifier == "h"
                ? (unsigned ? 65535 : 32767) : (unsigned ? 4_294_967_295 : 2_147_483_647)
            let minimum: Int64 =
              unsigned ? 0 : modifier == "hh" ? -128 : modifier == "h" ? -32768 : -2_147_483_648
            guard number >= minimum, number <= maximum else { throw OtaFailure.incompatible }
          }
          value = unsigned ? UInt64(number) : number
        } else {
          guard modifier.isEmpty || modifier == "l", let decimal = argument.pluralValue,
            let number = Double(decimal), number.isFinite
          else { throw OtaFailure.incompatible }
          value = number
        }
        output += String(format: spec, locale: Locale(identifier: languageTag), arguments: [value])
      }
      guard output.utf8.count <= 1_000_000 else { throw OtaFailure.incompatible }
      position = match.range.location + match.range.length
    }
    guard output.utf8.count <= 1_000_000 else { throw OtaFailure.incompatible }
    return (output, cursor)
  }
}

indirect enum CatalogNode: Sendable {
  case text(String)
  case plural([String: CatalogNode])
  case device([String: CatalogNode])
  case substituted(CatalogNode, [String: CatalogSubstitution])
  func raw(device: OtaDevice = .other) -> String? {
    switch self {
    case .text(let text): return text
    case .device(let branches):
      return (branches[device.rawValue] ?? branches["other"])?.raw(device: device)
    case .plural(let branches): return branches["other"]?.raw(device: device)
    case .substituted(let value, _): return value.raw(device: device)
    }
  }
  func render(
    arguments: [OtaArgument], languageTag: String, device: OtaDevice, startingAt: Int = 0,
    substitutions: [String: CatalogSubstitution] = [:], depth: Int = 0
  ) throws -> (String, Int) {
    guard depth < 16 else { throw OtaFailure.incompatible }
    switch self {
    case .text(let template):
      return try AppleFormat.render(
        template, arguments: arguments, languageTag: languageTag, startingAt: startingAt
      ) { name, index in
        guard let substitution = substitutions[name] else { throw OtaFailure.incompatible }
        let selected = substitution.argument.map { $0 - 1 } ?? index
        let result = try substitution.value.render(
          arguments: arguments, languageTag: languageTag, device: device,
          startingAt: selected, substitutions: substitutions, depth: depth + 1)
        return (result.0, max(result.1, selected + 1))
      }
    case .plural(let branches):
      guard arguments.indices.contains(startingAt), let number = arguments[startingAt].pluralValue
      else { throw OtaFailure.incompatible }
      let category = try OtaPluralRules.category(decimal: number, languageTag: languageTag)
      guard let branch = branches[category] ?? branches["other"] else {
        throw OtaFailure.incompatible
      }
      return try branch.render(
        arguments: arguments, languageTag: languageTag, device: device, startingAt: startingAt,
        substitutions: substitutions, depth: depth + 1)
    case .device(let branches):
      guard let branch = branches[device.rawValue] ?? branches["other"] else {
        throw OtaFailure.incompatible
      }
      return try branch.render(
        arguments: arguments, languageTag: languageTag, device: device, startingAt: startingAt,
        substitutions: substitutions, depth: depth + 1)
    case .substituted(let node, let additional):
      return try node.render(
        arguments: arguments, languageTag: languageTag, device: device, startingAt: startingAt,
        substitutions: substitutions.merging(additional) { _, new in new }, depth: depth + 1)
    }
  }
}
struct CatalogSubstitution: Sendable {
  let argument: Int?
  let value: CatalogNode
}
