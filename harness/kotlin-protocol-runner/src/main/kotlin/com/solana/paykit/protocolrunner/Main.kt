package com.solana.paykit.protocolrunner

import com.solana.paykit.protocols.mpp.core.MppHeaders
import com.solana.paykit.protocols.mpp.core.PaymentCredential
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.put
import java.util.Base64
import kotlin.system.exitProcess

private val json = Json { ignoreUnknownKeys = true }

private val unsupported = setOf(
    "challenge.format",
    "credential.parse",
    "receipt.parse",
    "receipt.format",
    "base64url.encode",
    "base64url.decode",
    "challenge.id",
)

fun main() {
    val response = respond(System.`in`.readBytes().decodeToString())
    println(response)
    if (json.parseToJsonElement(response).jsonObject["error_type"] == JsonPrimitive("runner_error")) {
        exitProcess(1)
    }
}

internal fun respond(line: String): String {
    val request = try {
        json.parseToJsonElement(line).jsonObject
    } catch (error: IllegalArgumentException) {
        return failure(error.message ?: "malformed request", "runner_error")
    }
    val op = (request["op"] as? JsonPrimitive)?.content.orEmpty()
    val input = request["input"] ?: JsonNull
    return try {
        when (op) {
            "challenge.parse" -> success(parseChallenge(input))
            "credential.format" -> success(buildJsonObject { put("header", formatCredential(input)) })
            in unsupported -> failure("$op unsupported by the Kotlin SDK", family(op))
            else -> failure("unknown operation: $op", "unsupported_operation")
        }
    } catch (error: Exception) {
        failure(error.message ?: error.toString(), family(op))
    }
}

private fun parseChallenge(input: JsonElement): JsonObject {
    val challenge = MppHeaders.parseWWWAuthenticate(input.jsonObject.getValue("header").jsonPrimitive.content)
    return buildJsonObject {
        put("id", challenge.id)
        put("realm", challenge.realm)
        put("method", challenge.method)
        put("intent", challenge.intent)
        put("request", decodeJson(challenge.request))
        challenge.expires?.let { put("expires", it) }
        challenge.digest?.let { put("digest", it) }
        challenge.opaque?.let { put("opaque", decodeJson(it)) }
    }
}

private fun formatCredential(input: JsonElement): String {
    val credential = input.jsonObject
    val challenge = credential.getValue("challenge").jsonObject
    val request = challenge["request"] ?: JsonObject(emptyMap())
    val encoded = Base64.getUrlEncoder().withoutPadding().encodeToString(request.toString().encodeToByteArray())
    val wire = JsonObject(credential + ("challenge" to JsonObject(challenge + ("request" to JsonPrimitive(encoded)))))
    return MppHeaders.formatAuthorization(json.decodeFromJsonElement(PaymentCredential.serializer(), wire))
}

private fun decodeJson(value: String): JsonElement =
    json.parseToJsonElement(Base64.getUrlDecoder().decode(value).decodeToString())

private fun family(op: String): String = when {
    op.endsWith(".parse") -> "parse_error"
    op.endsWith(".format") -> "format_error"
    op.startsWith("base64url.") -> "encoding_error"
    else -> "generation_error"
}

private fun success(result: JsonElement): String =
    buildJsonObject {
        put("success", true)
        put("result", result)
    }.toString()

private fun failure(error: String, errorType: String): String =
    buildJsonObject {
        put("success", false)
        put("error", error)
        put("error_type", errorType)
    }.toString()
