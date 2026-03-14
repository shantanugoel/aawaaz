import XCTest
@testable import Aawaaz

final class InsertionContextTests: XCTestCase {

    // MARK: - TextFieldType

    func testTextFieldTypeCodable() throws {
        let types: [InsertionContext.TextFieldType] = [
            .singleLine, .multiLine, .comboBox, .webArea, .unknown
        ]

        for type in types {
            let data = try JSONEncoder().encode(type)
            let decoded = try JSONDecoder().decode(InsertionContext.TextFieldType.self, from: data)
            XCTAssertEqual(decoded, type)
        }
    }

    // MARK: - InsertionMethod

    func testInsertionMethodCodable() throws {
        let methods: [InsertionContext.InsertionMethod] = [
            .accessibility, .keystrokeSimulation, .clipboardOnly
        ]

        for method in methods {
            let data = try JSONEncoder().encode(method)
            let decoded = try JSONDecoder().decode(InsertionContext.InsertionMethod.self, from: data)
            XCTAssertEqual(decoded, method)
        }
    }

    func testInsertionMethodRawValues() {
        XCTAssertEqual(InsertionContext.InsertionMethod.accessibility.rawValue, "accessibility")
        XCTAssertEqual(InsertionContext.InsertionMethod.keystrokeSimulation.rawValue, "keystrokeSimulation")
        XCTAssertEqual(InsertionContext.InsertionMethod.clipboardOnly.rawValue, "clipboardOnly")
    }

    // MARK: - AppCategory

    func testAppCategoryCodable() throws {
        for category in InsertionContext.AppCategory.allCases {
            let data = try JSONEncoder().encode(category)
            let decoded = try JSONDecoder().decode(InsertionContext.AppCategory.self, from: data)
            XCTAssertEqual(decoded, category)
        }
    }

    func testAppCategoryExactMatch() {
        let context = InsertionContext(
            appName: "Slack",
            bundleIdentifier: "com.tinyspeck.slackmacgap",
            fieldType: .multiLine
        )
        XCTAssertEqual(context.appCategory, .chat)
    }

    func testAppCategoryPrefixMatch() {
        let context = InsertionContext(
            appName: "CLion",
            bundleIdentifier: "com.jetbrains.CLion",
            fieldType: .multiLine
        )
        XCTAssertEqual(context.appCategory, .code)
    }

    func testAppCategoryFallsBackToOther() {
        let context = InsertionContext(
            appName: "SomeRandomApp",
            bundleIdentifier: "com.example.random",
            fieldType: .unknown
        )
        XCTAssertEqual(context.appCategory, .other)
    }

    func testAppCategoryUserOverrideWins() {
        let bundleID = "com.test.override-target"
        let key = "appCategory.\(bundleID)"
        UserDefaults.standard.set("email", forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }

        let context = InsertionContext(
            appName: "TestApp",
            bundleIdentifier: bundleID,
            fieldType: .unknown
        )
        XCTAssertEqual(context.appCategory, .email)
    }

    func testAppCategoryInvalidOverrideIgnored() {
        let bundleID = "com.test.invalid-override"
        let key = "appCategory.\(bundleID)"
        UserDefaults.standard.set("nonexistent_category", forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }

        let context = InsertionContext(
            appName: "TestApp",
            bundleIdentifier: bundleID,
            fieldType: .unknown
        )
        XCTAssertEqual(context.appCategory, .other)
    }

    // MARK: - Unknown Context

    func testUnknownContext() {
        let unknown = InsertionContext.unknown
        XCTAssertEqual(unknown.appName, "Unknown")
        XCTAssertEqual(unknown.bundleIdentifier, "")
        XCTAssertEqual(unknown.fieldType, .unknown)
        XCTAssertEqual(unknown.appCategory, .other)
    }
}
