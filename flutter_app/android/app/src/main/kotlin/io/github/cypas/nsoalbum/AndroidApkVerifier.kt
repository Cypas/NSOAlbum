package io.github.cypas.nsoalbum

import android.content.Context
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.os.Build
import java.io.File
import java.security.MessageDigest
import java.util.zip.ZipFile

internal object AndroidApkVerifier {
    fun validate(context: Context, file: File, spec: AndroidUpdateSpec) {
        if (!file.isFile || file.length() != spec.size || file.length() > AndroidUpdatePolicy.MAX_SIZE) {
            throw AndroidUpdateException("DOWNLOAD_TOO_LARGE")
        }
        file.inputStream().buffered().use { input ->
            AndroidUpdateFiles.copyVerified(input, null, spec)
        }
        val packageManager = context.packageManager
        @Suppress("DEPRECATION")
        val flags = if (Build.VERSION.SDK_INT >= 28) PackageManager.GET_SIGNING_CERTIFICATES
            else PackageManager.GET_SIGNATURES
        @Suppress("DEPRECATION")
        val archive = packageManager.getPackageArchiveInfo(file.absolutePath, flags)
            ?: throw AndroidUpdateException("INVALID_APK")
        @Suppress("DEPRECATION")
        val installed = packageManager.getPackageInfo(context.packageName, flags)
        val error = AndroidUpdatePolicy.artifactError(
            archive.packageName, archive.versionName, versionCode(archive),
            versionCode(installed), spec.version, signers(installed), signers(archive),
        )
        if (error != null) throw AndroidUpdateException(error)
        ZipFile(file).use { archiveFile ->
            var hasArm64Library = false
            val entries = archiveFile.entries()
            while (entries.hasMoreElements()) {
                val entry = entries.nextElement()
                if (entry.name.startsWith("lib/") && entry.name.endsWith(".so")) {
                    if (!entry.name.startsWith("lib/arm64-v8a/")) {
                        throw AndroidUpdateException("INVALID_APK")
                    }
                    hasArm64Library = true
                }
            }
            if (!hasArm64Library) throw AndroidUpdateException("INVALID_APK")
        }
    }

    @Suppress("DEPRECATION")
    private fun versionCode(info: PackageInfo): Long =
        if (Build.VERSION.SDK_INT >= 28) info.longVersionCode else info.versionCode.toLong()

    @Suppress("DEPRECATION")
    private fun signers(info: PackageInfo): Set<String> {
        val signatures = if (Build.VERSION.SDK_INT >= 28) info.signingInfo?.apkContentsSigners
            else info.signatures
        return signatures?.map {
            hex(MessageDigest.getInstance("SHA-256").digest(it.toByteArray()))
        }?.toSet() ?: emptySet()
    }

    private fun hex(bytes: ByteArray): String =
        bytes.joinToString("") { "%02x".format(it.toInt() and 0xff) }
}
