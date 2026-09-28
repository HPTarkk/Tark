package com.b1101.tark.security

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * Android-Keystore-backed string storage for app secrets: the install key,
 * the signed subscription entitlement and, later, session tokens.
 *
 * Same scheme as [RoomIdentitySecureStorageHandler] — AES-GCM ciphertext in
 * an app-private file, non-exportable master key — but with its own key alias
 * and directory, so a failure or wipe in one never touches the other.
 * Fails closed: an unreadable entry is deleted and reported, never guessed.
 */
class AppSecureStorageHandler(
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
            result.error("secure_storage_failed", "App secure storage failed closed", null)
        }
    }

    private fun write(call: MethodCall, result: MethodChannel.Result) {
        val value = call.argument<String>("value") ?: throw IllegalArgumentException("missing value")
        require(value.length <= MAX_VALUE_CHARS) { "value too large" }
        val target = fileFor(key(call))
        val tmp = File(target.parentFile, "${target.name}.tmp")
        tmp.writeBytes(encrypt(value.toByteArray(Charsets.UTF_8)))
        if (!tmp.renameTo(target)) {
            tmp.delete()
            throw IllegalStateException("atomic secure write failed")
        }
        result.success(null)
    }

    private fun read(call: MethodCall, result: MethodChannel.Result) {
        val target = fileFor(key(call))
        if (!target.exists()) {
            result.success(null)
            return
        }
        try {
            result.success(String(decrypt(target.readBytes()), Charsets.UTF_8))
        } catch (error: Throwable) {
            target.delete()
            throw error
        }
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

    private fun encrypt(plaintext: ByteArray): ByteArray {
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, masterKey())
        val ciphertext = cipher.doFinal(plaintext)
        val iv = cipher.iv
        require(iv.size <= 255)
        return byteArrayOf(FORMAT_VERSION, iv.size.toByte()) + iv + ciphertext
    }

    private fun decrypt(blob: ByteArray): ByteArray {
        require(blob.size > 2 && blob[0] == FORMAT_VERSION) { "unsupported secure format" }
        val ivSize = blob[1].toInt() and 0xff
        require(ivSize in 12..32 && blob.size > 2 + ivSize) { "invalid secure blob" }
        val iv = blob.copyOfRange(2, 2 + ivSize)
        val ciphertext = blob.copyOfRange(2 + ivSize, blob.size)
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.DECRYPT_MODE, masterKey(), GCMParameterSpec(128, iv))
        return cipher.doFinal(ciphertext)
    }

    private fun masterKey(): SecretKey {
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

    companion object {
        const val METHOD_CHANNEL = "tark/app_secure_storage"
        private const val DIRECTORY = "app_secure"
        private const val KEY_ALIAS = "tark_app_secure_master_v1"
        private const val TRANSFORMATION = "AES/GCM/NoPadding"
        private const val FORMAT_VERSION: Byte = 1
        private const val MAX_VALUE_CHARS = 16 * 1024
        private val KEY_PATTERN = Regex("^[a-z][a-z0-9_]{0,63}$")
    }
}
