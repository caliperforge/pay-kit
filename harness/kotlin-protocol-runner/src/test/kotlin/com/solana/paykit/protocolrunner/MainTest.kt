package com.solana.paykit.protocolrunner

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

class MainTest {
    private fun respondTo(line: String): JsonObject {
        val output = respond(line)
        assertFalse(output.contains('\n'), output)
        return Json.parseToJsonElement(output).jsonObject
    }

    @Test
    fun parsesBasicChallenge() {
        val response = respondTo(
            """{"op":"challenge.parse","input":{"header":"Payment id=\"ch_abc123\", realm=\"api.example.com\", method=\"tempo\", intent=\"charge\", request=\"eyJhbW91bnQiOiIxMDAwMDAwIiwiY3VycmVuY3kiOiIweDIwYzAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDAwMDEiLCJyZWNpcGllbnQiOiIweDEyMzQ1Njc4OTBhYmNkZWYxMjM0NTY3ODkwYWJjZGVmMTIzNDU2NzgifQ\""}}""",
        )
        val golden = Json.parseToJsonElement(
            """{"id":"ch_abc123","intent":"charge","method":"tempo","realm":"api.example.com","request":{"amount":"1000000","currency":"0x20c0000000000000000000000000000000000001","recipient":"0x1234567890abcdef1234567890abcdef12345678"}}""",
        )
        assertEquals(JsonPrimitive(true), response["success"])
        assertEquals(golden, response["result"])
    }

    @Test
    fun refusesNonJsonStdin() {
        val response = respondTo("not json")
        assertEquals(JsonPrimitive(false), response["success"])
        assertEquals(JsonPrimitive("runner_error"), response["error_type"])
    }

    @Test
    fun reportsUnknownOperation() {
        val response = respondTo("""{"op":"nope.op","input":{}}""")
        assertEquals(JsonPrimitive(false), response["success"])
        assertEquals(JsonPrimitive("unsupported_operation"), response["error_type"])
    }

    @Test
    fun reportsMissingSdkFunctionAsFamilyError() {
        val response = respondTo("""{"op":"receipt.parse","input":{"header":"eyJ9"}}""")
        assertEquals(JsonPrimitive(false), response["success"])
        assertEquals(JsonPrimitive("parse_error"), response["error_type"])
        assertTrue(response.getValue("error").jsonPrimitive.content.contains("unsupported"))
    }
}
