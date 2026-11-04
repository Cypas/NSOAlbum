package io.github.cypas.nsoalbum

import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream

// Run as a JVM main with the pure update policy/files sources; no device or release keys are used.
object AndroidUpdatePolicyTest {
    @JvmStatic
    fun main(args: Array<String>) {
        val valid = mapOf(
            "version" to "0.2.15",
            "url" to "https://github.com/Cypas/NSOAlbum/releases/download/v0.2.15/NSOAlbum-Android-arm64-0.2.15.apk",
            "sha256" to "a".repeat(64),
            "size" to 100L,
            "userAgent" to "Cypas-NSOAlbum/0.2.14",
            "language" to "en",
        )
        check(AndroidUpdatePolicy.parse(valid, "0.2.14").size == 100L)
        fun reject(field: String, value: Any) {
            check(runCatching {
                AndroidUpdatePolicy.parse(valid + (field to value), "0.2.14")
            }.isFailure) { "Accepted invalid $field: $value" }
        }
        reject("version", "0.2.14")
        reject("version", "0.2.15-beta")
        reject("version", "00.2.15")
        reject("version", "../0.2.15")
        reject("url", "${valid["url"]}?token=secret")
        reject("url", "https://github.com.evil.invalid/Cypas/NSOAlbum/releases/download/v0.2.15/NSOAlbum-Android-arm64-0.2.15.apk")
        reject("url", "https://github.com/Other/NSOAlbum/releases/download/v0.2.15/NSOAlbum-Android-arm64-0.2.15.apk")
        reject("sha256", "A".repeat(64))
        reject("sha256", "a".repeat(63))
        reject("size", 0L)
        reject("size", 512L * 1024 * 1024 + 1)
        reject("size", 100.5)
        reject("userAgent", "Cypas-NSOAlbum/0.2.15")
        reject("language", "fr")
        check(AndroidUpdatePolicy.parse(valid + ("size" to 512L * 1024 * 1024), "0.2.14").size ==
            512L * 1024 * 1024)
        check(AndroidUpdatePolicy.parse(
            valid + mapOf("version" to "0.10.0",
                "url" to "https://github.com/Cypas/NSOAlbum/releases/download/v0.10.0/NSOAlbum-Android-arm64-0.10.0.apk"),
            "0.2.14").version == "0.10.0")

        fun artifactError(
            packageName: String = "io.github.cypas.nsoalbum",
            version: String = "0.2.15",
            versionCode: Long = 48,
            installedSigners: Set<String> = setOf("installed"),
            archiveSigners: Set<String> = setOf("installed"),
        ) = AndroidUpdatePolicy.artifactError(
            packageName, version, versionCode, 47, "0.2.15", installedSigners, archiveSigners)
        check(artifactError() == null)
        check(artifactError(packageName = "io.squidalbum.squid_album") == "PACKAGE_MISMATCH")
        check(artifactError(version = "0.2.16") == "VERSION_MISMATCH")
        check(artifactError(versionCode = 47) == "VERSION_NOT_NEWER")
        check(artifactError(versionCode = 46) == "VERSION_NOT_NEWER")
        check(artifactError(archiveSigners = setOf("different")) == "SIGNATURE_MISMATCH")
        check(artifactError(archiveSigners = emptySet()) == "SIGNATURE_MISMATCH")
        check(artifactError(installedSigners = emptySet()) == "SIGNATURE_MISMATCH")
        check(artifactError(archiveSigners = setOf("installed", "extra")) == "SIGNATURE_MISMATCH")
        val threeBytes = AndroidUpdatePolicy.parse(valid + mapOf(
            "size" to 3L,
            "sha256" to "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
        ), "0.2.14")
        val copied = ByteArrayOutputStream()
        AndroidUpdateFiles.copyVerified(ByteArrayInputStream("abc".toByteArray()), copied, threeBytes)
        check(copied.toString("UTF-8") == "abc")
        fun fileError(content: String, spec: AndroidUpdateSpec = threeBytes): String? =
            runCatching {
                AndroidUpdateFiles.copyVerified(
                    ByteArrayInputStream(content.toByteArray()), ByteArrayOutputStream(), spec)
            }.exceptionOrNull()?.message
        check(fileError("abd") == "HASH_MISMATCH")
        check(fileError("ab") == "INVALID_APK")
        check(fileError("abcd") == "DOWNLOAD_TOO_LARGE")
        check(fileError("") == "INVALID_APK")
        val oversizedOutput = ByteArrayOutputStream()
        check(runCatching {
            AndroidUpdateFiles.copyVerified(
                ByteArrayInputStream(ByteArray(1024 * 1024)), oversizedOutput, threeBytes)
        }.isFailure)
        check(oversizedOutput.size() <= 3)
        val cancellation = AndroidUpdateCancellation()
        cancellation.cancel()
        val stoppedOutput = ByteArrayOutputStream()
        check(runCatching {
            AndroidUpdateFiles.copyVerified(
                ByteArrayInputStream("abc".toByteArray()), stoppedOutput, threeBytes, cancellation)
        }.exceptionOrNull()?.message == "VERIFICATION_INTERRUPTED")
        check(stoppedOutput.size() == 0)
        check(AndroidUpdatePolicy.matchesJob("verifying", 12, "nonce", 12, "nonce"))
        check(AndroidUpdatePolicy.matchesJob("downloading", 12, "nonce", 12, "nonce"))
        check(!AndroidUpdatePolicy.matchesJob("failed", 12, "nonce", 12, "nonce"))
        check(!AndroidUpdatePolicy.matchesJob("ready", 12, "nonce", 12, "nonce"))
        check(!AndroidUpdatePolicy.matchesJob("verifying", 12, "nonce", 13, "nonce"))
        check(!AndroidUpdatePolicy.matchesJob("verifying", 12, "nonce", 12, "other"))
        check(!AndroidUpdatePolicy.matchesJob("verifying", -1, "nonce", -1, "nonce"))
        check(!AndroidUpdatePolicy.matchesJob("verifying", 12, null, 12, null))
        println("Android update policy and bounded file verification: all checks passed")
    }
}
