package com.b1101.tark.security

import android.content.Context
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.io.File
import java.security.MessageDigest

/**
 * Android-Keystore-backed persistence for Room transport identity material.
 *
 * Plaintext private keys never enter SharedPreferences or disk. Only AES-GCM
 * ciphertext is written to the app-private files directory and the AES master
 * key is non-exportable in Android Keystore (see [KeystoreSealer]).
 *
 * The same sealed file format also keeps the one Room rejoin ticket: the
 * network a phone was on when its app stopped mid-call, so it can get back on
 * without a code. There is only ever one, so it has a fixed name.
 *
 * Errors: `secure_storage_failed` when an entry can never be opened (it is
 * deleted, so repeated reads cannot recover through a fallback);
 * `secure_storage_unavailable` for a temporary Keystore or disk failure, with
 * the entry kept — a member's identity must not be lost to a hiccup.
 * Registered on a background task queue, like [AppSecureStorageHandler].
 */
class RoomIdentitySecureStorageHandler(
    private val context: Context,
) : MethodChannel.MethodCallHandler {
    private val sealer = KeystoreSealer(KEY_ALIAS)

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "write" -> write(call, result)
                "read" -> read(call, result)
                "delete" -> delete(call, result)
                "writeRejoin" -> writeRejoin(call, result)
                "readRejoin" -> readRejoin(result)
                "deleteRejoin" -> {
                    fileFor(REJOIN_SCOPE).delete()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        } catch (error: KeystoreSealer.CorruptSecretException) {
            result.error(AppSecureStorageHandler.ERROR_FAILED, "Room identity entry was unreadable and removed", null)
        } catch (error: IllegalArgumentException) {
            result.error(AppSecureStorageHandler.ERROR_FAILED, "Room identity secure storage refused the request", null)
        } catch (error: Throwable) {
            result.error(AppSecureStorageHandler.ERROR_UNAVAILABLE, "Room identity secure storage is temporarily unavailable", null)
        }
    }

    private fun write(call: MethodCall, result: MethodChannel.Result) {
        seal(scope(call), call)
        result.success(null)
    }

    private fun writeRejoin(call: MethodCall, result: MethodChannel.Result) {
        seal(REJOIN_SCOPE, call)
        result.success(null)
    }

    private fun seal(scope: String, call: MethodCall) {
        @Suppress("UNCHECKED_CAST")
        val material = call.argument<Map<String, Any?>>("material")
            ?: throw IllegalArgumentException("missing material")
        val plaintext = JSONObject(material).toString().toByteArray(Charsets.UTF_8)
        sealer.writeFile(fileFor(scope), plaintext)
    }

    private fun read(call: MethodCall, result: MethodChannel.Result) {
        open(scope(call), result)
    }

    private fun readRejoin(result: MethodChannel.Result) {
        open(REJOIN_SCOPE, result)
    }

    private fun open(scope: String, result: MethodChannel.Result) {
        result.success(
            sealer.readFile(fileFor(scope)) { plaintext ->
                jsonToMap(JSONObject(String(plaintext, Charsets.UTF_8)))
            },
        )
    }

    private fun delete(call: MethodCall, result: MethodChannel.Result) {
        fileFor(scope(call)).delete()
        result.success(null)
    }

    private fun scope(call: MethodCall): String {
        val roomId = call.argument<String>("roomId") ?: ""
        val memberId = call.argument<String>("memberId") ?: ""
        require(ROOM_ID.matches(roomId)) { "invalid room scope" }
        require(MEMBER_ID.matches(memberId)) { "invalid member scope" }
        return "$roomId:$memberId"
    }

    private fun fileFor(scope: String): File {
        val directory = File(context.filesDir, DIRECTORY)
        if (!directory.exists() && !directory.mkdirs()) {
            throw IllegalStateException("secure identity directory unavailable")
        }
        val digest = MessageDigest.getInstance("SHA-256")
            .digest(scope.toByteArray(Charsets.UTF_8))
            .joinToString("") { "%02x".format(it) }
        return File(directory, "$digest.bin")
    }

    private fun jsonToMap(json: JSONObject): Map<String, Any?> {
        val result = mutableMapOf<String, Any?>()
        val keys = json.keys()
        while (keys.hasNext()) {
            val key = keys.next()
            result[key] = if (json.isNull(key)) null else json.get(key)
        }
        return result
    }

    companion object {
        const val METHOD_CHANNEL = "tark/room_identity_secure_storage"
        private const val DIRECTORY = "room_identity_secure"
        private const val KEY_ALIAS = "tark_room_identity_master_v1"
        private val ROOM_ID = Regex("^[0-9a-f]{32}$")
        private val MEMBER_ID = Regex("^[0-9a-f]{24}$")

        // Never a valid identity scope (those are "<32 hex>:<24 hex>").
        private const val REJOIN_SCOPE = "rejoin-ticket:v1"
    }
}
