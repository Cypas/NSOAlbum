package io.github.cypas.nsoalbum

internal data class AndroidDisplayModePreference(
    val id: Int,
    val width: Int,
    val height: Int,
    val refreshRate: Float,
)

internal object AndroidDisplayModePolicy {
    const val MAX_REFRESH_RATE = 120f

    fun select(
        currentWidth: Int,
        currentHeight: Int,
        modes: List<AndroidDisplayModePreference>,
    ): AndroidDisplayModePreference? = modes
        .asSequence()
        .filter { mode ->
            mode.width == currentWidth &&
                mode.height == currentHeight &&
                mode.refreshRate.isFinite() &&
                mode.refreshRate > 0f &&
                mode.refreshRate <= MAX_REFRESH_RATE + 0.5f
        }
        .maxByOrNull { it.refreshRate }
}
