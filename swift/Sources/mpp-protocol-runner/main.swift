// Command mpp-protocol-runner is the Swift mpp-protocol conformance runner:
// one adapter-ABI request on stdin, one response line on stdout, per the
// contract in harness/src/protocol/runners/spawn.ts.

import Foundation
import SolanaPayKit

struct RunnerError: Error, CustomStringConvertible {
    var errorType: String?
    let description: String
}

func respond(to raw: Data) -> (line: String, exitCode: Int32) {
    guard let request = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any],
          let op = request["op"] as? String
    else {
        return (failure("request must be a JSON object with a string op", "runner_error"), 1)
    }
    do {
        return (serialize(["success": true, "result": try run(op, request["input"])]), 0)
    } catch {
        return (failure(String(describing: error), (error as? RunnerError)?.errorType ?? family(of: op)), 0)
    }
}

func run(_ op: String, _ input: Any?) throws -> Any {
    switch op {
    case "challenge.parse":
        return try parseChallenge(object(input, at: "input"))
    case "credential.format":
        return ["header": try MppHeaders.formatAuthorization(credential(from: object(input, at: "input")))]
    case "challenge.format":
        throw unsupported(op, "WWW-Authenticate formatter")
    case "credential.parse":
        throw unsupported(op, "Authorization parser")
    case "receipt.parse":
        throw unsupported(op, "Payment-Receipt parser")
    case "receipt.format":
        throw unsupported(op, "Payment-Receipt formatter")
    case "base64url.encode":
        throw unsupported(op, "public base64url encoder")
    case "base64url.decode":
        throw unsupported(op, "public base64url decoder")
    case "challenge.id":
        throw unsupported(op, "challenge-id generator")
    default:
        throw RunnerError(errorType: "unsupported_operation", description: "Unknown operation: \(op)")
    }
}

func family(of op: String) -> String {
    if op.hasPrefix("base64url.") { return "encoding_error" }
    if op == "challenge.id" { return "generation_error" }
    return op.hasSuffix(".parse") ? "parse_error" : "format_error"
}

func unsupported(_ op: String, _ thing: String) -> RunnerError {
    RunnerError(description: "\(op) unsupported: SolanaPayKit has no \(thing)")
}

enum ChallengeFields {
    static let all: Set<String> = ["id", "realm", "method", "intent", "request", "expires", "digest", "opaque"]
    // Spec challenge params PaymentChallenge cannot carry; extension params are ignored per spec.
    static let unrepresentable: Set<String> = ["description"]
}

func parseChallenge(_ input: [String: Any]) throws -> [String: Any] {
    let header = try string(input, "header", at: "") ?? ""
    let challenge = try MppHeaders.parseWWWAuthenticate(header)
    let params = header.matches(of: #/[\s,]*([^=\s,"]+)\s*=\s*"(?:[^"\\]|\\.)*"/#).map { String($0.1) }
    if let param = params.first(where: ChallengeFields.unrepresentable.contains) {
        throw RunnerError(description: "unsupported field \(param)")
    }
    var result: [String: Any] = [
        "id": challenge.id,
        "realm": challenge.realm,
        "method": challenge.method,
        "intent": challenge.intent,
        "request": try decodeJSON(challenge.request),
    ]
    if let expires = challenge.expires { result["expires"] = expires }
    if let digest = challenge.digest { result["digest"] = digest }
    if let opaque = challenge.opaque { result["opaque"] = try decodeJSON(opaque) }
    return result
}

func credential(from input: [String: Any]) throws -> PaymentCredential {
    try rejectUnknownKeys(input, ["challenge", "payload", "source"], at: "")
    let challenge = try object(input["challenge"], at: "challenge")
    try rejectUnknownKeys(challenge, ChallengeFields.all, at: "challenge.")
    let payload = try object(input["payload"], at: "payload")
    try rejectUnknownKeys(payload, ["type", "transaction", "signature"], at: "payload.")
    guard let request = challenge["request"] else { throw RunnerError(description: "missing challenge.request") }
    let echo = try PaymentChallenge(
        id: required(challenge, "id", at: "challenge."),
        realm: required(challenge, "realm", at: "challenge."),
        method: required(challenge, "method", at: "challenge."),
        intent: required(challenge, "intent", at: "challenge."),
        request: encodeJSON(request),
        expires: string(challenge, "expires", at: "challenge."),
        digest: string(challenge, "digest", at: "challenge."),
        opaque: challenge["opaque"].map(encodeJSON)
    ).echo()
    return PaymentCredential(
        challenge: echo,
        payload: try JSONDecoder().decode(CredentialPayload.self, from: JSONSerialization.data(withJSONObject: payload)),
        source: try string(input, "source", at: "")
    )
}

func object(_ value: Any?, at path: String) throws -> [String: Any] {
    guard let object = value as? [String: Any] else { throw RunnerError(description: "\(path) must be a JSON object") }
    return object
}

func string(_ object: [String: Any], _ key: String, at path: String) throws -> String? {
    guard let value = object[key] else { return nil }
    guard let string = value as? String else { throw RunnerError(description: "\(path)\(key) must be a string") }
    return string
}

func required(_ object: [String: Any], _ key: String, at path: String) throws -> String {
    guard let value = try string(object, key, at: path) else { throw RunnerError(description: "missing \(path)\(key)") }
    return value
}

func rejectUnknownKeys(_ object: [String: Any], _ allowed: Set<String>, at path: String) throws {
    if let key = object.keys.sorted().first(where: { !allowed.contains($0) }) {
        throw RunnerError(description: "unsupported field \(path)\(key)")
    }
}

func decodeJSON(_ base64url: String) throws -> Any {
    var base64 = base64url.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
    guard let data = Data(base64Encoded: base64) else { throw RunnerError(description: "invalid base64url: \(base64url)") }
    return try JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
}

func encodeJSON(_ value: Any) throws -> String {
    try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed])
        .base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

func failure(_ message: String, _ errorType: String) -> String {
    serialize(["success": false, "error": message, "error_type": errorType])
}

func serialize(_ response: [String: Any]) -> String {
    String(decoding: try! JSONSerialization.data(withJSONObject: response, options: .sortedKeys), as: UTF8.self)
}

let response = respond(to: FileHandle.standardInput.readDataToEndOfFile())
FileHandle.standardOutput.write(Data((response.line + "\n").utf8))
exit(response.exitCode)
