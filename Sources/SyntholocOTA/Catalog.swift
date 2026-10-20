import Foundation

struct Catalog: Sendable {
  var strings: [String: String] = [:]
  var plurals: [String: [String: [String: String]]] = [:]
  var entries: [String: CatalogNode] = [:]
  var languageTag = "en"
  static func parse(format: String, data: Data, languageTag: String) throws -> Catalog {
    var result = Catalog()
    result.languageTag = languageTag
    guard data.count <= 10_000_000 else { throw OtaFailure.integrity }
    guard let source = String(data: data, encoding: .utf8), !source.contains("\0") else {
      throw OtaFailure.invalidManifest
    }
    if format == "JSON_FLAT" || format == "JSON_NESTED" {
      guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw OtaFailure.invalidManifest
      }
      func visit(_ object: [String: Any], _ prefix: String, _ depth: Int) throws {
        try Wire.require(depth < 40)
        for (key, value) in object {
          try Wire.require(!["__proto__", "constructor", "prototype"].contains(key))
          let path = prefix.isEmpty ? key : prefix + "." + key
          if let text = value as? String {
            try Wire.require(result.strings[path] == nil)
            result.strings[path] = text
            result.entries[path] = .text(text)
          } else if let child = value as? [String: Any], format == "JSON_NESTED" {
            try visit(child, path, depth + 1)
          } else {
            throw OtaFailure.invalidManifest
          }
        }
      }
      try visit(root, "", 0)
      return result
    }
    if format == "IOS_STRINGS" || format == "IOS_STRINGSDICT" {
      if source.range(of: "<!ENTITY", options: .caseInsensitive)
        != nil
      {
        throw OtaFailure.invalidManifest
      }
      guard
        let object = try PropertyListSerialization.propertyList(from: data, format: nil)
          as? [String: Any]
      else { throw OtaFailure.invalidManifest }
      for (key, value) in object {
        if format == "IOS_STRINGS" {
          guard let text = value as? String else { throw OtaFailure.invalidManifest }
          result.strings[key] = text
          result.entries[key] = .text(text)
        } else {
          guard let dictionary = value as? [String: Any],
            let template = dictionary["NSStringLocalizedFormatKey"] as? String
          else { throw OtaFailure.invalidManifest }
          var substitutions: [String: CatalogSubstitution] = [:]
          for (variable, rule) in dictionary where variable != "NSStringLocalizedFormatKey" {
            guard let forms = rule as? [String: Any],
              forms["NSStringFormatSpecTypeKey"] as? String == "NSStringPluralRuleType",
              let specifier = forms["NSStringFormatValueTypeKey"] as? String,
              Wire.matches(specifier, "^(ll|l|h|hh|z|j|t)?[diuoxXfFeEgG]$")
            else { throw OtaFailure.incompatible }
            var values: [String: CatalogNode] = [:]
            var raw: [String: String] = [:]
            for category in ["zero", "one", "two", "few", "many", "other"] {
              if let text = forms[category] as? String {
                values[category] = .text(text)
                raw[category] = text
              }
            }
            try Wire.require(values["other"] != nil)
            substitutions[variable] = .init(argument: nil, value: .plural(values))
            result.plurals[key, default: [:]][variable] = raw
          }
          try Wire.require(!substitutions.isEmpty)
          result.strings[key] = template
          result.entries[key] = .substituted(.text(template), substitutions)
        }
      }
      return result
    }
    guard format == "IOS_XCSTRINGS",
      let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let source = root["sourceLanguage"] as? String, Wire.language(source),
      let strings = root["strings"] as? [String: [String: Any]]
    else { throw OtaFailure.incompatible }
    for (key, value) in strings {
      guard let localizations = value["localizations"] as? [String: [String: Any]],
        let localized = localizations[languageTag]
      else { continue }
      let node = try parseNode(localized, depth: 0)
      result.entries[key] = node
      result.strings[key] = node.raw()
      if case .plural(let forms) = node {
        result.plurals[key] = ["value": forms.compactMapValues { $0.raw() }]
      }
    }
    return result
  }
  private static func parseNode(
    _ object: [String: Any], depth: Int, argument: Int? = nil, specifier: String? = nil
  ) throws -> CatalogNode {
    try Wire.require(depth < 16)
    let node: CatalogNode
    if let unit = object["stringUnit"] as? [String: Any], let raw = unit["value"] as? String {
      try Wire.require(object["variations"] == nil)
      if let argument = argument, let specifier = specifier {
        node = .text(raw.replacingOccurrences(of: "%arg", with: "%\(argument)$\(specifier)"))
      } else {
        node = .text(raw)
      }
    } else if let variations = object["variations"] as? [String: Any], variations.count == 1 {
      if let plural = variations["plural"] as? [String: [String: Any]] {
        try Wire.require(
          plural["other"] != nil
            && plural.keys.allSatisfy {
              ["zero", "one", "two", "few", "many", "other"].contains($0)
            })
        node = .plural(
          try plural.mapValues {
            try parseNode($0, depth: depth + 1, argument: argument, specifier: specifier)
          })
      } else if let device = variations["device"] as? [String: [String: Any]] {
        try Wire.require(!device.isEmpty && device.count <= 16)
        node = .device(
          try device.mapValues {
            try parseNode($0, depth: depth + 1, argument: argument, specifier: specifier)
          })
      } else {
        throw OtaFailure.incompatible
      }
    } else {
      throw OtaFailure.invalidManifest
    }
    if object["substitutions"] != nil {
      guard let substitutions = object["substitutions"] as? [String: [String: Any]] else {
        throw OtaFailure.invalidManifest
      }
      try Wire.require(substitutions.count <= 128)
      var variables: [String: CatalogSubstitution] = [:]
      for (name, value) in substitutions {
        guard Wire.matches(name, "^[A-Za-z0-9_]{1,80}$"), let number = value["argNum"] as? Int,
          (1...128).contains(number),
          let spec = value["formatSpecifier"] as? String,
          Wire.matches(spec, "^(ll|l|h|hh|z|j|t)?[diuoxXfFeEgG@]$")
        else { throw OtaFailure.invalidManifest }
        variables[name] = .init(
          argument: number,
          value: try parseNode(value, depth: depth + 1, argument: number, specifier: spec))
      }
      return .substituted(node, variables)
    }
    return node
  }
}
