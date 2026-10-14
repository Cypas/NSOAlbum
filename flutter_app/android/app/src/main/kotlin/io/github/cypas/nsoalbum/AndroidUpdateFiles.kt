package io.github.cypas.nsoalbum

import java.io.InputStream
import java.io.OutputStream
import java.security.MessageDigest

internal object AndroidUpdateFiles {
    fun copyVerified(
        input: InputStream,
        output: OutputStream?,
        spec: AndroidUpdateSpec,
        cancellation: AndroidUpdateCancellation? = null,
    ) {
        val digest = MessageDigest.getInstance("SHA-256")
        val buffer = ByteArray(64 * 1024)
        var received = 0L
        while (true) {
            cancellation?.throwIfCanceled()
            val count = input.read(buffer)
            if (count < 0) break
            received += count
            if (received > spec.size || received > AndroidUpdatePolicy.MAX_SIZE) {
                throw AndroidUpdateException("DOWNLOAD_TOO_LARGE")
            }
            digest.update(buffer, 0, count)
            output?.write(buffer, 0, count)
        }
        cancellation?.throwIfCanceled()
        if (received != spec.size) throw AndroidUpdateException("INVALID_APK")
        val hash = digest.digest().joinToString("") { "%02x".format(it.toInt() and 0xff) }
        if (hash != spec.sha256) throw AndroidUpdateException("HASH_MISMATCH")
    }
}
