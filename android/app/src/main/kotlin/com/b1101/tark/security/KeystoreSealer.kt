package com.b1101.tark.security

import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyPermanentlyInvalidatedException
import android.security.keystore.KeyProperties
import org.json.JSONException
import java.io.File
import java.security.KeyStore
import javax.crypto.AEADBadTagException
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * AES-GCM sealing under a non-exportable Android Keystore key, shared by the
 * app's secure stores. Blob format (unchanged from the first release, so
 * every file already on a phone still opens):
 *
 *     [version=1][iv length][iv][ciphertext + 16-byte tag]
 *
 * Failures come in two kinds, and only one of them may cost data:
 *  - [CorruptSecretException]: the bytes can never be opened (wrong tag, bad
 *    format, a key that was wiped or permanently invalidated). Callers delete
 *    the entry — keeping it would fail the same way forever.
 *  - anything else (the Keystore daemon busy or not ready yet after boot, an
 *    I/O error): temporary. Retried a few times here, then reported, and the
 *    entry is kept so the next attempt can still read it.
 */
internal class KeystoreSealer(private val keyAlias: String) {

    /** Bytes that will never decrypt; the entry should be removed. */
    class CorruptSecretException(cause: Throwable) : Exception(cause)

    fun seal(plaintext: ByteArray): ByteArray = retryingTransient {
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, key())
        val ciphertext = cipher.doFinal(plaintext)
        val iv = cipher.iv
        require(iv.size <= 255)
        byteArrayOf(FORMAT_VERSION, iv.size.toByte()) + iv + ciphertext
    }

    /** @throws CorruptSecretException when [blob] can never be opened. */
    fun open(blob: ByteArray): ByteArray {
        if (blob.size <= 2 || blob[0] != FORMAT_VERSION) {
            throw CorruptSecretException(IllegalArgumentException("unsupported secure format"))
        }
        val ivSize = blob[1].toInt() and 0xff
        if (ivSize !in 12..32 || blob.size <= 2 + ivSize) {
            throw CorruptSecretException(IllegalArgumentException("invalid secure blob"))
        }
        val iv = blob.copyOfRange(2, 2 + ivSize)
        val ciphertext = blob.copyOfRange(2 + ivSize, blob.size)
        return retryingTransient {
            try {
                val cipher = Cipher.getInstance(TRANSFORMATION)
                cipher.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, iv))
                cipher.doFinal(ciphertext)
            } catch (error: AEADBadTagException) {
                throw CorruptSecretException(error)
            } catch (error: KeyPermanentlyInvalidatedException) {
                throw CorruptSecretException(error)
            }
        }
    }

    /**
     * Reads [file] and opens it. A missing file is null; a corrupt one is
     * deleted and reported; a temporary failure leaves it in place.
     */
    fun <T> readFile(file: File, decode: (ByteArray) -> T): T? {
        if (!file.exists()) return null
        val blob = retryingTransient { file.readBytes() }
        try {
            return try {
                decode(open(blob))
            } catch (error: JSONException) {
                throw CorruptSecretException(error)
            }
        } catch (error: CorruptSecretException) {
            file.delete()
            throw error
        }
    }

    /** Seals [plaintext] into [file] atomically (write a temp file, rename). */
    fun writeFile(file: File, plaintext: ByteArray) {
        val sealed = seal(plaintext)
        val tmp = File(file.parentFile, "${file.name}.tmp")
        tmp.writeBytes(sealed)
        if (!tmp.renameTo(file)) {
            tmp.delete()
            throw IllegalStateException("atomic secure write failed")
        }
    }

    private fun key(): SecretKey {
        val keyStore = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (keyStore.getKey(keyAlias, null) as? SecretKey)?.let { return it }

        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        generator.init(
            KeyGenParameterSpec.Builder(
                keyAlias,
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

    /**
     * Runs [block], retrying failures that may be temporary. Runs on the
     * channel's background task queue, so the short sleeps never touch the UI.
     */
    private fun <T> retryingTransient(block: () -> T): T {
        var attempt = 0
        while (true) {
            try {
                return block()
            } catch (error: CorruptSecretException) {
                throw error
            } catch (error: Exception) {
                if (++attempt >= TRANSIENT_ATTEMPTS) throw error
                Thread.sleep(TRANSIENT_BACKOFF_MS * attempt)
            }
        }
    }

    companion object {
        private const val TRANSFORMATION = "AES/GCM/NoPadding"
        private const val FORMAT_VERSION: Byte = 1
        private const val TRANSIENT_ATTEMPTS = 3
        private const val TRANSIENT_BACKOFF_MS = 60L
    }
}
