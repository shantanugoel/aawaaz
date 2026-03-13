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
}
