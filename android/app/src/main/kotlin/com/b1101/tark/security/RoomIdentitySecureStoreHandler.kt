package com.b1101.tark.security

import android.content.Context
import android.os.Build
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.nio.charset.StandardCharsets
import java.security.KeyStore
import java.security.MessageDigest
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * Stores opaque Room transport identity records encrypted with an AES/GCM key
 * that never leaves AndroidKeyStore.
 *
 * SharedPreferences contains ciphertext only. The record key is a SHA-256 scope
 * digest; neither plaintext private-key material nor a transport address/device
 * identifier is persisted or logged by this handler.
 */
class RoomIdentitySecureStoreHandler(
    context: Context,
) : MethodChannel.MethodCallHandler {
    companion object {
        const val METHOD_CHANNEL = "tark/room_identity_secure_store"
        private const val PREFS = "room_identity_secure_store_v1"
        private const val MASTER_ALIAS = "tark_room_identity_master_v1"
        private const val MAX_SECRET_CHARS = 8192
        private val ROOM_ID = Regex("^[0-9a-f]{32}$")
        private val MEMBER_ID = Regex("^[0-9a-f]{24}$")
    }

    private val preferences = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) {
            result.error("secure_store_unavailable", "AndroidKeyStore AES/GCM unavailable", null)
            return
        }

        val roomId = call.argument<String>("roomId")?.trim()?.lowercase()
        val memberId = call.argument<String>("memberId")?.trim()?.lowercase()
        if (roomId == null || memberId == null || !ROOM_ID.matches(roomId) || !MEMBER_ID.matches(memberId)) {
            result.error("invalid_scope", "Invalid Room identity scope", null)
            return
        }

        val recordKey = recordKey(roomId, memberId)
        try {
            when (call.method) {
                "write" -> {
                    val secret = call.argument<String>("secret")
                    if (secret.isNullOrEmpty() || secret.length > MAX_SECRET_CHARS) {
                        result.error("invalid_secret", "Invalid Room identity record", null)
                        return
                    }
                    val encrypted = encrypt(secret, recordKey)
                    if (!preferences.edit().putString(recordKey, encrypted).commit()) {
                        result.error("persist_failed", "Unable to persist encrypted Room identity", null)
                        return
                    }
                    result.success(null)
                }

                "read" -> {
                    val encrypted = preferences.getString(recordKey, null)
                    if (encrypted == null) {
                        result.success(null)
                        return
                    }
                    try {
                        result.success(decrypt(encrypted, recordKey))
                    } catch (error: Exception) {
                        // Corrupt/undecryptable ciphertext must not be retried as
                        // identity authority. Remove it and fail closed.
                        preferences.edit().remove(recordKey).commit()
                        result.error("corrupt_secret", "Room identity record is unreadable", null)
                    }
                }

                "delete" -> {
                    if (!preferences.edit().remove(recordKey).commit()) {
                        result.error("delete_failed", "Unable to delete Room identity", null)
                        return
                    }
                    result.success(null)
                }

                else -> result.notImplemented()
            }
        } catch (error: Exception) {
            result.error("secure_store_failed", "Room identity secure storage failed", null)
        }
    }

    private fun encrypt(plaintext: String, recordKey: String): String {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, masterKey())
        cipher.updateAAD(recordKey.toByteArray(StandardCharsets.UTF_8))
        val ciphertext = cipher.doFinal(plaintext.toByteArray(StandardCharsets.UTF_8))
        return Base64.encodeToString(cipher.iv, Base64.NO_WRAP) + "." +
            Base64.encodeToString(ciphertext, Base64.NO_WRAP)
    }

    private fun decrypt(encoded: String, recordKey: String): String {
        val separator = encoded.indexOf('.')
        require(separator > 0 && separator < encoded.length - 1)
        val iv = Base64.decode(encoded.substring(0, separator), Base64.NO_WRAP)
        val ciphertext = Base64.decode(encoded.substring(separator + 1), Base64.NO_WRAP)
        require(iv.size == 12)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, masterKey(), GCMParameterSpec(128, iv))
        cipher.updateAAD(recordKey.toByteArray(StandardCharsets.UTF_8))
        return String(cipher.doFinal(ciphertext), StandardCharsets.UTF_8)
    }

    private fun masterKey(): SecretKey {
        val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        val existing = keyStore.getKey(MASTER_ALIAS, null) as? SecretKey
        if (existing != null) return existing

        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        generator.init(
            KeyGenParameterSpec.Builder(
                MASTER_ALIAS,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
            ).setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setRandomizedEncryptionRequired(true)
                .build(),
        )
        return generator.generateKey()
    }

    private fun recordKey(roomId: String, memberId: String): String {
        val digest = MessageDigest.getInstance("SHA-256")
            .digest("$roomId:$memberId".toByteArray(StandardCharsets.UTF_8))
        return digest.joinToString(separator = "") { byte -> "%02x".format(byte) }
    }
}
