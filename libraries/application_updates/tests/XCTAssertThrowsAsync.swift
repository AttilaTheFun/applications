import XCTest

/// That an async call throws `expected`.
func XCTAssertThrowsAsync<E: Error & Equatable>(_ call: @autoclosure () async throws -> some Any, _ expected: E,
                                                file: StaticString = #filePath, line: UInt = #line) async {
    do {
        _ = try await call()
        XCTFail("no error, expected \(expected)", file: file, line: line)
    } catch let error as E {
        XCTAssertEqual(error, expected, file: file, line: line)
    } catch {
        XCTFail("\(error), expected \(expected)", file: file, line: line)
    }
}
