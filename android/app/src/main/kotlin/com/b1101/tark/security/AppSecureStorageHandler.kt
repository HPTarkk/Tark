package com.b1101.tark.security

import android.content.Context
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * Android-Keystore-backed string storage for app secrets: the install key,
 * the signed subscription entitlement and the account's session tokens.
 *
 * Same scheme as [RoomIdentitySecureStorageHandler] — AES-GCM ciphertext in
 * an app-private file, non-exportable master key (see [KeystoreSealer]) — but
 * with its own key alias and directory, so a failure or wipe in one never
 * touches the other.
 *
 * Fails closed without losing data to a passing hiccup: an entry that can
 * never be decrypted is deleted and reported as `secure_storage_failed`; a
 * temporary Keystore or disk failure is reported as
 * `secure_storage_unavailable` and the entry is kept for the next try (deleting
 * it would sign the user out, or cost the install its identity, for good).
 *
 * Registered on a background task queue: Keystore calls can take tens of
 * milliseconds and the file I/O has no place on the UI thread.
 */
class AppSecureStorageHandler(
    private val context: Context,
) : MethodChannel.MethodCallHandler {
    private val sealer = KeystoreSealer(KEY_ALIAS)

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "write" -> write(call, result)
                "read" -> read(call, result)
                "delete" -> delete(call, result)
                else -> result.notImplemented()
            }
        } catch (error: KeystoreSealer.CorruptSecretException) {
            result.error(ERROR_FAILED, "App secure storage entry was unreadable and removed", null)
        } catch (error: IllegalArgumentException) {
            result.error(ERROR_FAILED, "App secure storage refused the request", null)
        } catch (error: Throwable) {
            result.error(ERROR_UNAVAILABLE, "App secure storage is temporarily unavailable", null)
        }
    }

    private fun write(call: MethodCall, result: MethodChannel.Result) {
        val value = call.argument<String>("value") ?: throw IllegalArgumentException("missing value")
        require(value.length <= MAX_VALUE_CHARS) { "value too large" }
        sealer.writeFile(fileFor(key(call)), value.toByteArray(Charsets.UTF_8))
        result.success(null)
    }

    private fun read(call: MethodCall, result: MethodChannel.Result) {
        result.success(sealer.readFile(fileFor(key(call))) { String(it, Charsets.UTF_8) })
    }

    private fun delete(call: MethodCall, result: MethodChannel.Result) {
        fileFor(key(call)).delete()
        result.success(null)
    }

    private fun key(call: MethodCall): String {
        val key = call.argument<String>("key") ?: ""
        require(KEY_PATTERN.matches(key)) { "invalid key" }
        return key
    }

    private fun fileFor(key: String): File {
        val directory = File(context.filesDir, DIRECTORY)
        if (!directory.exists() && !directory.mkdirs()) {
            throw IllegalStateException("secure directory unavailable")
        }
        return File(directory, "$key.bin")
    }

    companion object {
        const val METHOD_CHANNEL = "tark/app_secure_storage"
        const val ERROR_FAILED = "secure_storage_failed"
        const val ERROR_UNAVAILABLE = "secure_storage_unavailable"
        private const val DIRECTORY = "app_secure"
        private const val KEY_ALIAS = "tark_app_secure_master_v1"
        private const val MAX_VALUE_CHARS = 16 * 1024
        private val KEY_PATTERN = Regex("^[a-z][a-z0-9_]{0,63}$")
    }
}
