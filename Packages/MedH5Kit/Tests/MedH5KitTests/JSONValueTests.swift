import XCTest
@testable import MedH5Kit

final class JSONValueTests: XCTestCase {
    func testIntegersAndFloatsStayApartAndKeysKeepTheirOrder() throws {
        let text = #"{"b": 1, "a": 1.0, "c": [1, 2.5, -0.0, 1e-05, 12345678901234567890], "d": {"z": null, "y": true}}"#
        let value = try JSONValue.parse(text)
        XCTAssertEqual(value["b"], .int(1))
        XCTAssertEqual(value["a"], .double(1))
        XCTAssertNotEqual(value["b"], value["a"], "1 is not 1.0")
        XCTAssertEqual(value["c"]?[4], .uint(12345678901234567890))
        XCTAssertEqual(value.objectValue?.keys, ["b", "a", "c", "d"])
        XCTAssertEqual(value.serialized(.meta), text)
        XCTAssertEqual(value.serialized(.compact), #"{"b":1,"a":1.0,"c":[1,2.5,-0.0,1e-05,12345678901234567890],"d":{"z":null,"y":true}}"#)
        XCTAssertEqual(value.serialized(.canonical), #"{"a":1.0,"b":1,"c":[1,2.5,-0.0,1e-05,12345678901234567890],"d":{"y":true,"z":null}}"#)
    }

    func testFloatsArePythonsRepr() {
        let cases: [(Double, String)] = [
            (0.1, "0.1"), (1, "1.0"), (100, "100.0"), (1e16, "1e+16"), (1e15, "1000000000000000.0"),
            (1.2345678901234568e17, "1.2345678901234568e+17"), (0.0001, "0.0001"), (0.00001, "1e-05"),
            (1.5e-7, "1.5e-07"), (-2.5, "-2.5"), (6.25, "6.25"), (1.0 / 3, "0.3333333333333333"),
            (5e-324, "5e-324"), (1.7976931348623157e308, "1.7976931348623157e+308"), (0, "0.0"), (-0.0, "-0.0"),
            (.nan, "NaN"), (.infinity, "Infinity"), (-.infinity, "-Infinity"), (2.0e-4, "0.0002"),
            (115.93826821870643, "115.93826821870643"), (9007199254740992, "9007199254740992.0"),
        ]
        for (value, expected) in cases {
            XCTAssertEqual(JSONValue.pythonRepr(value), expected, "\(value)")
        }
    }

    func testStringsEscapeAsPythonDoes() throws {
        let value: JSONValue = ["text": "é \"q\" \\ \n\t\u{01} 🦴 /"]
        XCTAssertEqual(value.serialized(.meta), "{\"text\": \"é \\\"q\\\" \\\\ \\n\\t\\u0001 🦴 /\"}")
        XCTAssertEqual(value.serialized(.pretty), "{\n  \"text\": \"\\u00e9 \\\"q\\\" \\\\ \\n\\t\\u0001 \\ud83e\\uddb4 /\"\n}")
        let parsed = try JSONValue.parse(#"{"s": "é🦴\/x"}"#)
        XCTAssertEqual(parsed["s"]?.stringValue, "é🦴/x")
        XCTAssertEqual(try JSONValue.parse(value.serialized(.pretty)), value)
    }

    func testMalformedTextIsRefusedAndLegacyNonFiniteIsRead() throws {
        for bad in ["", "{", "[1,]", "{\"a\" 1}", "01x", "\"unterminated", "{\"a\":1} x", "[1e]"] {
            XCTAssertThrowsError(try JSONValue.parse(bad), bad)
        }
        let legacy = try JSONValue.parse("[NaN, Infinity, -Infinity]")
        XCTAssertEqual(legacy.serialized(.meta), "[NaN, Infinity, -Infinity]")
        let deep = String(repeating: "[", count: 600) + String(repeating: "]", count: 600)
        XCTAssertThrowsError(try JSONValue.parse(deep))
    }

    func testEditingKeepsOrderAndRemovingDropsTheKey() throws {
        var object = try JSONValue.parse(#"{"x": 1, "y": 2}"#)
        object["z"] = .int(3)
        object["x"] = .double(1.5)
        object["y"] = nil
        XCTAssertEqual(object.serialized(.compact), #"{"x":1.5,"z":3}"#)
    }

    func testDecodingKeepsNestedValuesExactly() throws {
        struct Model: Decodable {
            var id: Int
            var ratio: Double
            var extra: JSONValue
            var missing: String?
        }
        let model = try JSONValue.parse(#"{"id": 3, "ratio": 2, "extra": {"n": 1, "f": 1.0}, "missing": null}"#).decode(Model.self)
        XCTAssertEqual(model.id, 3)
        XCTAssertEqual(model.ratio, 2)
        XCTAssertNil(model.missing)
        XCTAssertEqual(model.extra.serialized(), #"{"n":1,"f":1.0}"#)
        XCTAssertThrowsError(try JSONValue.parse(#"{"id": 1.5, "ratio": 2, "extra": null}"#).decode(Model.self))
    }

    func testTheStoredDocumentRoundTripsByteForByte() throws {
        let sample = try SampleFile.open(Fixtures.demo)
        defer { sample.close() }
        let stored = try sample.documentText()
        let parsed = try JSONValue.parse(stored)
        XCTAssertEqual(parsed.serialized(.meta), stored)
        // Integers stayed integers, floats floats.
        XCTAssertEqual(parsed["acquisition"]?["CT_tp0"]?["KVP"], .int(120))
        XCTAssertEqual(parsed["acquisition"]?["CT_tp0"]?["SliceThickness"], .double(6.25))
        XCTAssertEqual(parsed["timepoints"]?[1]?["days_from_baseline"], .int(92))
    }
}
