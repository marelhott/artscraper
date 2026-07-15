import XCTest
@testable import ArtScraper

final class SearchModelsTests: XCTestCase {
    func testFlexibleIDDecodesStringAndInteger() throws {
        XCTAssertEqual(try JSONDecoder().decode(FlexibleID.self, from: Data("\"abc\"".utf8)).value, "abc")
        XCTAssertEqual(try JSONDecoder().decode(FlexibleID.self, from: Data("42".utf8)).value, "42")
    }
}
