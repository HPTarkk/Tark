package com.b1101.tark.security

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import java.io.File
import java.security.KeyStore
import java.security.MessageDigest
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * Android-Keystore-backed persistence for Room transport identity material.
 *
 * Plaintext private keys never enter SharedPreferences or disk. Only AES-GCM
 * ciphertext is written to the app-private files directory and the AES master
 * key is non-exportable in Android Keystore.
 */
class RoomIdentitySecureStorageHandler(
    private val context: Context,
) : MethodChannel.MethodCallHandler {
    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "write" -> write(call, result)
                "read" -> read(call, result)
                "delete" -> delete(call, result)
                else -> result.notImplemented()
            }
        } catch (error: Throwable) {
            result.error("secure_storage_failed", "Room identity secure storage failed closed", null)
        }
    }

    private fun write(call: MethodCall, result: MethodChannel.Result) {
        val scope = scope(call)
        @Suppress("UNCHECKED_CAST")
        val material = call.argument<Map<String, Any?>>("material")
            ?: throw IllegalArgumentException("missing material")
        val plaintext = JSONObject(material).toString().toByteArray(Charsets.UTF_8)
        val encrypted = encrypt(plaintext)
        val target = fileFor(scope)
        val tmp = File(target.parentFile, "${target.name}.tmp")
        tmp.writeBytes(encrypted)
        if (!tmp.renameTo(target)) {
            tmp.delete()
            throw IllegalStateException("atomic secure identity write failed")
        }
        result.success(null)
    }

    private fun read(call: MethodCall, result: MethodChannel.Result) {
        val scope = scope(call)
        val target = fileFor(scope)
        if (!target.exists()) {
            result.success(null)
            return
        }
        try {
            val plaintext = decrypt(target.readBytes())
            val json = JSONObject(String(plaintext, Charsets.UTF_8))
            result.success(jsonToMap(json))
        } catch (error: Throwable) {
            // Corrupt/tampered ciphertext is unusable identity state. Remove it
            // so repeated reads cannot accidentally recover through a fallback.
            target.delete()
            throw error
        }
    }

    private fun delete(call: MethodCall, result: MethodChannel.Result) {
        fileFor(scope(call)).delete()
        result.success(null)
    }

    private fun scope(call: MethodCall): String {
        val roomId = call.argument<String>("roomId") ?: ""
        val memberId = call.argument<String>("memberId") ?: ""
        require(Regex("^[0-9a-f]{32}$").matches(roomId)) { "invalid room scope" }
        require(Regex("^[0-9a-f]{24}$").matches(memberId)) { "invalid member scope" }
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

    private fun encrypt(plaintext: ByteArray): ByteArray {
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, key())
        val ciphertext = cipher.doFinal(plaintext)
        val iv = cipher.iv
        require(iv.size <= 255)
        return byteArrayOf(FORMAT_VERSION, iv.size.toByte()) + iv + ciphertext
    }

    private fun decrypt(blob: ByteArray): ByteArray {
        require(blob.size > 2 && blob[0] == FORMAT_VERSION) { "unsupported secure identity format" }
        val ivSize = blob[1].toInt() and 0xff
        require(ivSize in 12..32 && blob.size > 2 + ivSize) { "invalid secure identity blob" }
        val iv = blob.copyOfRange(2, 2 + ivSize)
        val ciphertext = blob.copyOfRange(2 + ivSize, blob.size)
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, iv))
        return cipher.doFinal(ciphertext)
    }

    private fun key(): SecretKey {
        val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (keyStore.getKey(KEY_ALIAS, null) as? SecretKey)?.let { return it }

        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        generator.init(
            KeyGenParameterSpec.Builder(
                KEY_ALIAS,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .setRandomizedEncryptionRequired(true)
                .build(),
        )
        return generator.generateKey()
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
        private const val TRANSFORMATION = "AES/GCM/NoPadding"
        private const val FORMAT_VERSION: Byte = 1
    }
}
