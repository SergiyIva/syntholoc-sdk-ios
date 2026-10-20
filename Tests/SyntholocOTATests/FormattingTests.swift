import XCTest

@testable import SyntholocOTA

final class FormattingTests: XCTestCase {
  func testPackagedCLDRAndVisibleDecimals() throws {
    try OtaPluralRules.validatePackagedRules()
    let cases: [(String, String, String)] = [
      ("ru", "1", "one"), ("ru", "2", "few"), ("ru", "5", "many"), ("ru", "21", "one"),
      ("ru", "1.0", "other"), ("ru", "-22", "few"), ("ar", "0", "zero"), ("ar", "2", "two"),
      ("ar", "11", "many"), ("ar", "0.5", "other"), ("en", "1.00", "other"),
      ("pt", "0", "one"), ("pt-PT", "0", "other"), ("fr", "1000000", "many"),
      ("ja", "1", "other"), ("ru", "9223372036854775807", "many"),
    ]
    for (locale, number, expected) in cases {
      XCTAssertEqual(
        try OtaPluralRules.category(decimal: number, languageTag: locale), expected,
        "\(locale) \(number)")
    }
    XCTAssertThrowsError(try OtaPluralRules.category(decimal: "nan", languageTag: "en"))
  }

  func testTypedPositionalFormattingAndUnsafeConversions() throws {
    XCTAssertEqual(
      try AppleFormat.render(
        "%2$@ / %1$lld / %%", arguments: [.integer(4_000_000_000), .string("name")],
        languageTag: "en_US_POSIX"
      ).0, "name / 4000000000 / %")
    XCTAssertEqual(
      try AppleFormat.render(
        "%04d %.2f", arguments: [.integer(7), .number(2.5)], languageTag: "en_US_POSIX"
      ).0, "0007 2.50")
    for template in ["%s", "%n", "%p", "%*d", "%99999d", "%0$@", "%129$@", "%Lf"] {
      XCTAssertThrowsError(
        try AppleFormat.render(template, arguments: [.integer(7)], languageTag: "en"), template)
    }
    XCTAssertThrowsError(try AppleFormat.render("%@", arguments: [.integer(7)], languageTag: "en"))
    XCTAssertThrowsError(
      try AppleFormat.render("%d", arguments: [.integer(Int64.max)], languageTag: "en"))
  }

  func testXCStringsDevicePluralSubstitutionAndEmptyOverride() throws {
    let object: [String: Any] = [
      "sourceLanguage": "en", "version": "1.0",
      "strings": [
        "message": [
          "localizations": [
            "ru": [
              "stringUnit": ["value": "%1$@ — %#@items@"],
              "substitutions": [
                "items": [
                  "argNum": 2, "formatSpecifier": "lld",
                  "variations": [
                    "plural": [
                      "one": ["stringUnit": ["value": "%arg item"]],
                      "few": ["stringUnit": ["value": "%arg items few"]],
                      "other": ["stringUnit": ["value": "%arg items"]],
                    ]
                  ],
                ]
              ],
            ]
          ]
        ],
        "device": [
          "localizations": [
            "ru": [
              "variations": [
                "device": [
                  "iphone": ["stringUnit": ["value": "Phone"]],
                  "other": ["stringUnit": ["value": "Other"]],
                ]
              ]
            ]
          ]
        ],
        "empty": ["localizations": ["ru": ["stringUnit": ["value": ""]]]],
      ],
    ]
    let catalog = try Catalog.parse(
      format: "IOS_XCSTRINGS", data: JSONSerialization.data(withJSONObject: object),
      languageTag: "ru")
    let snapshot = OtaLocalizationSnapshot(
      releaseId: "release1", catalogs: ["ru/app": catalog], locales: ["ru"])
    XCTAssertEqual(
      snapshot.formatted(
        namespace: "app", key: "message", arguments: [.string("User"), .integer(22)],
        fallback: "Bundled"), "User — 22 items few")
    XCTAssertEqual(
      snapshot.formatted(
        namespace: "app", key: "device", arguments: [], device: .iphone, fallback: "Bundled"),
      "Phone")
    XCTAssertEqual(snapshot.string(namespace: "app", key: "empty", fallback: "Bundled"), "")
    XCTAssertEqual(
      snapshot.string(namespace: "app", key: "removed", fallback: "Bundled"), "Bundled")
    XCTAssertEqual(
      snapshot.formatted(
        namespace: "app", key: "message", arguments: [.string("Bad")], fallback: "Bundled"),
      "Bundled")
    XCTAssertEqual(
      snapshot.provider(tables: ["Localizable": "app"]).localizedString(
        forKey: "empty", value: "Bundled"), "")
    XCTAssertEqual(
      snapshot.provider(tables: ["Other": "app"]).localizedString(
        forKey: "empty", value: "Bundled"), "Bundled")
  }

  func testStringsDictMultiplePluralVariables() throws {
    func rule(_ one: String, _ other: String) -> [String: String] {
      [
        "NSStringFormatSpecTypeKey": "NSStringPluralRuleType", "NSStringFormatValueTypeKey": "lld",
        "one": one, "other": other,
      ]
    }
    let object: [String: Any] = [
      "files": [
        "NSStringLocalizedFormatKey": "%#@files@ and %#@folders@",
        "files": rule("%lld file", "%lld files"), "folders": rule("%lld folder", "%lld folders"),
      ]
    ]
    let data = try PropertyListSerialization.data(
      fromPropertyList: object, format: .xml, options: 0)
    let catalog = try Catalog.parse(format: "IOS_STRINGSDICT", data: data, languageTag: "en")
    let snapshot = OtaLocalizationSnapshot(
      releaseId: nil, catalogs: ["en/app": catalog], locales: ["en"])
    XCTAssertEqual(
      snapshot.formatted(
        namespace: "app", key: "files", arguments: [.integer(1), .integer(3)], fallback: "Bundled"),
      "1 file and 3 folders")
  }
}
