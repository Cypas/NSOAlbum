package io.github.cypas.nsoalbum

internal class AndroidUpdateException(val code: String) : Exception(code)

internal data class AndroidUpdateSpec(
    val version: String,
    val url: String,
    val sha256: String,
    val size: Long,
    val userAgent: String,
    val language: String,
)

internal object AndroidUpdatePolicy {
    const val PACKAGE_NAME = "io.github.cypas.nsoalbum"
    const val MAX_SIZE = 512L * 1024 * 1024
    private val versionPattern = Regex("(0|[1-9][0-9]{0,8})\\.(0|[1-9][0-9]{0,8})\\.(0|[1-9][0-9]{0,8})")
    private val hashPattern = Regex("[0-9a-f]{64}")

    fun parse(arguments: Map<*, *>, currentVersion: String): AndroidUpdateSpec {
        val version = arguments["version"] as? String ?: invalid()
        require(versionPattern.matches(version) && versionPattern.matches(currentVersion)) {
            "INVALID_UPDATE"
        }
        val candidateParts = version.split('.').map(String::toLong)
        val currentParts = currentVersion.split('.').map(String::toLong)
        val firstDifferent = candidateParts.indices.firstOrNull {
            candidateParts[it] != currentParts[it]
        }
        require(firstDifferent != null && candidateParts[firstDifferent] > currentParts[firstDifferent]) {
            "VERSION_NOT_NEWER"
        }
        val expectedUrl = "https://github.com/Cypas/NSOAlbum/releases/download/v$version/" +
            "NSOAlbum-Android-arm64-$version.apk"
        val url = arguments["url"] as? String ?: invalid()
        val sha256 = arguments["sha256"] as? String ?: invalid()
        val rawSize = arguments["size"]
        val size = when (rawSize) {
            is Long -> rawSize
            is Int -> rawSize.toLong()
            else -> invalid()
        }
        val userAgent = arguments["userAgent"] as? String ?: invalid()
        val language = arguments["language"] as? String ?: invalid()
        require(url == expectedUrl && hashPattern.matches(sha256) &&
            size in 1..MAX_SIZE && userAgent == "Cypas-NSOAlbum/$currentVersion" &&
            language in setOf("zh", "en")) { "INVALID_UPDATE" }
        return AndroidUpdateSpec(version, url, sha256, size, userAgent, language)
    }

    fun artifactError(
        packageName: String,
        version: String?,
        versionCode: Long,
        installedVersionCode: Long,
        expectedVersion: String,
        installedSigners: Set<String>,
        archiveSigners: Set<String>,
    ): String? = when {
        packageName != PACKAGE_NAME -> "PACKAGE_MISMATCH"
        version != expectedVersion -> "VERSION_MISMATCH"
        versionCode <= installedVersionCode -> "VERSION_NOT_NEWER"
        installedSigners.isEmpty() || archiveSigners != installedSigners -> "SIGNATURE_MISMATCH"
        else -> null
    }

    fun matchesJob(
        state: String,
        savedId: Long,
        savedNonce: String?,
        currentId: Long,
        currentNonce: String?,
    ): Boolean = state in setOf("downloading", "verifying") &&
        savedId > 0 && savedId == currentId &&
        !savedNonce.isNullOrEmpty() && savedNonce == currentNonce

    private fun invalid(): Nothing = throw IllegalArgumentException("INVALID_UPDATE")
}

internal class AndroidUpdateCancellation {
    @Volatile
    var canceled: Boolean = false

    fun cancel() {
        canceled = true
    }

    fun throwIfCanceled() {
        if (canceled) throw AndroidUpdateException("VERIFICATION_INTERRUPTED")
    }
}
