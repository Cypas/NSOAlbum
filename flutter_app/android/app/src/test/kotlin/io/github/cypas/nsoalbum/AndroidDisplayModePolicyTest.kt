package io.github.cypas.nsoalbum

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class AndroidDisplayModePolicyTest {
    @Test
    fun choosesHighestSameResolutionModeAtOrBelow120() {
        val selected = AndroidDisplayModePolicy.select(
            currentWidth = 1080,
            currentHeight = 2400,
            modes = listOf(
                mode(1, 1440, 3200, 120f),
                mode(2, 1080, 2400, 60f),
                mode(3, 1080, 2400, 96f),
                mode(4, 1080, 2400, 120f),
            ),
        )

        assertEquals(4, selected?.id)
    }

    @Test
    fun capsHigherRefreshModesAt120() {
        val selected = AndroidDisplayModePolicy.select(
            currentWidth = 1080,
            currentHeight = 2400,
            modes = listOf(
                mode(1, 1080, 2400, 120f),
                mode(2, 1080, 2400, 144f),
            ),
        )

        assertEquals(1, selected?.id)
    }

    @Test
    fun keepsBestModeWhenOnly60IsAvailable() {
        val selected = AndroidDisplayModePolicy.select(
            currentWidth = 720,
            currentHeight = 1600,
            modes = listOf(mode(7, 720, 1600, 60f)),
        )

        assertEquals(7, selected?.id)
    }

    @Test
    fun rejectsOtherResolutionsAndInvalidRefreshRates() {
        val selected = AndroidDisplayModePolicy.select(
            currentWidth = 1080,
            currentHeight = 2400,
            modes = listOf(
                mode(1, 1440, 3200, 120f),
                mode(2, 1080, 2400, 0f),
                mode(3, 1080, 2400, Float.NaN),
            ),
        )

        assertNull(selected)
    }

    private fun mode(
        id: Int,
        width: Int,
        height: Int,
        refreshRate: Float,
    ) = AndroidDisplayModePreference(id, width, height, refreshRate)
}
