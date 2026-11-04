package io.github.cypas.nsoalbum

import org.junit.Assert.assertEquals
import org.junit.Test

class KeepAliveCleanupTest {
    @Test
    fun disposedKeepAliveEntryIsRemovedInsteadOfLeftAsNull() {
        val entries = mutableMapOf<String, String?>("retired-view" to "view")
        var disposeCount = 0

        retireKeepAliveEntry(entries, "retired-view") {
            disposeCount += 1
            entries[it] = null
        }

        assertEquals(1, disposeCount)
        assertEquals(false, entries.containsKey("retired-view"))
        assertEquals(emptyMap<String, String?>(), entries)
    }

    @Test
    fun disposingUnknownKeepAliveEntryIsIdempotent() {
        val entries = mutableMapOf<String, String?>()
        var disposeCount = 0

        retireKeepAliveEntry(entries, "already-retired") { disposeCount += 1 }

        assertEquals(0, disposeCount)
        assertEquals(emptyMap<String, String?>(), entries)
    }
}
