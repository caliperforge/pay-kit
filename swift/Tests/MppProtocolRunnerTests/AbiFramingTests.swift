import Foundation
import XCTest

@testable import mpp_protocol_runner

final class AbiFramingTests: XCTestCase {
    private let basicChallenge = #"Payment id="ch_abc123", realm="api.example.com", method="tempo", intent="charge", request="eyJhbW91bnQiOiIxMDAwMDAwIiwiY3VycmVuY3kiOiIweDIwYzAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDEiLCJyZWNpcGllbnQiOiIweDEyMzQ1Njc4OTBhYmNkZWYxMjM0NTY3ODkwYWJjZGVmMTIzNDU2NzgifQ""#

    private func call(_ request: Any) throws -> (response: [String: Any], exitCode: Int32) {
        let (line, exitCode) = respond(to: try JSONSerialization.data(withJSONObject: request))
        XCTAssertFalse(line.contains("\n"))
        let response = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        return (response, exitCode)
    }

    private func formatCredential(challenge: [String: Any] = [:], payload: [String: Any]) throws -> [String: Any] {
        var fullChallenge: [String: Any] = [
            "id": "ch_abc123", "realm": "api.example.com", "method": "tempo", "intent": "charge",
            "request": ["amount": "1000000"],
        ]
        fullChallenge.merge(challenge) { $1 }
        let (response, exitCode) = try call([
            "op": "credential.format", "input": ["challenge": fullChallenge, "payload": payload],
        ])
        XCTAssertEqual(exitCode, 0)
        return response
    }

    func testBasicChallengeParseIsOneLine() throws {
        let (response, exitCode) = try call(["op": "challenge.parse", "input": ["header": basicChallenge]])
        XCTAssertEqual(exitCode, 0)
        XCTAssertEqual(response["success"] as? Bool, true)
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["id"] as? String, "ch_abc123")
        XCTAssertEqual((result["request"] as? [String: Any])?["amount"] as? String, "1000000")
    }

    func testMalformedRequestIsRunnerError() throws {
        for raw in [Data("not json".utf8), Data(#"{"op":1}"#.utf8)] {
            let (line, exitCode) = respond(to: raw)
            XCTAssertEqual(exitCode, 1)
            let response = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            XCTAssertEqual(response["error_type"] as? String, "runner_error")
        }
    }

    func testUnknownOperationIsUnsupported() throws {
        let (response, exitCode) = try call(["op": "voucher.sign", "input": [:]])
        XCTAssertEqual(exitCode, 0)
        XCTAssertEqual(response["error_type"] as? String, "unsupported_operation")
        XCTAssertEqual(response["error"] as? String, "Unknown operation: voucher.sign")
    }

    func testCredentialFormatRejectsUnknownChallengeField() throws {
        let response = try formatCredential(
            challenge: ["description": "x"], payload: ["type": "transaction", "transaction": "AQ"]
        )
        XCTAssertEqual(response["error_type"] as? String, "format_error")
        XCTAssertEqual(response["error"] as? String, "unsupported field challenge.description")
    }

    func testCredentialFormatRejectsUnknownPayloadField() throws {
        let response = try formatCredential(payload: ["type": "hash", "hash": "0xabc"])
        XCTAssertEqual(response["error_type"] as? String, "format_error")
        XCTAssertEqual(response["error"] as? String, "unsupported field payload.hash")
    }

    func testCredentialFormatRequiresTransaction() throws {
        let response = try formatCredential(payload: ["type": "transaction", "signature": "0xabc"])
        XCTAssertEqual(response["error_type"] as? String, "format_error")
        XCTAssertTrue((response["error"] as? String ?? "").contains("transaction"))
    }
}
