import XCTest

@testable import SyntholocOTA

final class ContractTests: XCTestCase {
  func testLiteralDotsAndEmptyStrings() throws {
    let catalog = try Catalog.parse(
      format: "JSON_FLAT", data: Data(#"{"literal.dot":"Hello %@","empty":""}"#.utf8),
      languageTag: "en")
    XCTAssertEqual(catalog.strings["empty"], "")
    XCTAssertEqual(catalog.strings["literal.dot"], "Hello %@")
  }
  func testSha256() {
    XCTAssertEqual(
      OtaClient.sha(Data("hello".utf8)),
      "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
  }
  func testUnsafeCatalog() {
    XCTAssertThrowsError(
      try Catalog.parse(
        format: "JSON_FLAT", data: Data(#"{"__proto__":"x"}"#.utf8), languageTag: "en"))
    for data in [Data([0xff]), #"{"text":"UTF16"}"#.data(using: .utf16LittleEndian)!] {
      XCTAssertThrowsError(try Catalog.parse(format: "JSON_FLAT", data: data, languageTag: "en"))
    }
    let xml =
      "<?xml version=\"1.0\"?><!DOCTYPE plist [<!ENTITY value SYSTEM 'file:///invalid'>]><plist><dict/></plist>"
    XCTAssertThrowsError(
      try Catalog.parse(
        format: "IOS_STRINGSDICT", data: xml.data(using: .utf16LittleEndian)!, languageTag: "en"))
  }
  func testSharedWireFixture() throws {
    let directory = Bundle.module.resourceURL!.appendingPathComponent("Fixtures/wire")
    let channel = try JSONDecoder().decode(
      ChannelManifest.self, from: Data(contentsOf: directory.appendingPathComponent("channel.json"))
    )
    let bytes = try Data(contentsOf: directory.appendingPathComponent("release.json"))
    XCTAssertEqual(bytes.count, channel.release.bytes)
    XCTAssertEqual(OtaClient.sha(bytes), channel.release.sha256)
    let release = try JSONDecoder().decode(ReleaseManifest.self, from: bytes)
    try channel.validate()
    try release.validate()
    let asset = release.locales[0].assets[0]
    let data = try Data(contentsOf: directory.appendingPathComponent("asset.json"))
    XCTAssertEqual(data.count, asset.bytes)
    XCTAssertEqual(OtaClient.sha(data), asset.sha256)
  }

}
