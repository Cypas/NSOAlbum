package io.github.cypas.nsoalbum

import android.content.ContentResolver
import android.database.Cursor
import android.net.Uri
import android.os.CancellationSignal
import android.provider.DocumentsContract

object DeviceSyncSafDirectoryTest {
    @JvmStatic
    fun main(args: Array<String>) {
        val root = "primary:Documents/NSOAlbumSync"
        val tree = Uri(root)
        val provider = DirectoryProvider()
        val owner = DeviceSyncOperation("f".repeat(32), "a".repeat(32))
        val lookup = DeviceSyncSafDirectory(provider, tree, owner)
        repeat(120) { sequence ->
            val name = "s-" + sequence.toString(16).padStart(32, '0')
            provider.documents["$root/$name"] = SyncDocument("$root/$name", name, true, 0)
        }
        val sessionParent = "$root/s-" + "0".repeat(32)
        provider.documents["$sessionParent/mobile"] =
            SyncDocument("$sessionParent/mobile", "mobile", true, 0)
        val before = provider.documents.toMap()

        // Real providers may reject an absent fabricated document URI in
        // enforceTree/isChildDocument before queryDocument returns a cursor.
        val missing = "s-" + "e".repeat(32)
        check(lookup.find(root, missing) == null)
        check(lookup.find(root, "s-" + "0".repeat(32))?.id == sessionParent)
        check(lookup.find(sessionParent, "mobile")?.id == "$sessionParent/mobile")
        check(provider.documents == before)
        check(provider.queries.all { it.children })
        check(provider.queries.map { it.documentId } == listOf(root, root, sessionParent))
        check(provider.cursors.all { it.moves <= DeviceSyncPolicy.MAX_ENTRIES + 1 && it.closed })

        val calls = provider.queries.size
        for ((parent, name) in listOf(root to "../escape", "$root/unowned" to "mobile",
            sessionParent to "other", "$sessionParent/mobile" to "desktop")) {
            check(runCatching { lookup.find(parent, name) }.isFailure)
        }
        check(provider.queries.size == calls)

        provider.duplicate = true
        check(runCatching { lookup.find(root, "s-" + "0".repeat(32)) }.isFailure)
        check(provider.cursors.last().closed)
        provider.duplicate = false
        provider.virtual = true
        check(runCatching { lookup.find(root, "s-" + "0".repeat(32)) }.isFailure)
        provider.virtual = false
        provider.overrideRows = listOf(SyncDocument("outside", missing, true, 0))
        check(runCatching { lookup.find(root, missing) }.isFailure)
        provider.overrideRows = listOf(SyncDocument("$root/$missing", missing, false, 0))
        check(runCatching { lookup.find(root, missing) }.isFailure)
        provider.overrideRows = null

        // Null/denied/unsupported parent queries cannot establish child absence.
        for (failure in listOf(
            java.io.FileNotFoundException("synthetic-private-parent"),
            SecurityException("synthetic-private-uri"),
            IllegalArgumentException("synthetic-private-provider-detail"),
        )) {
            provider.failure = failure
            check(runCatching { lookup.find(root, missing) }.exceptionOrNull() === failure)
        }
        provider.failure = null
        provider.nullCursor = true
        check(runCatching { lookup.find(root, missing) }.isFailure)
        provider.nullCursor = false

        provider.overrideRows = List(DeviceSyncPolicy.MAX_ENTRIES) { index ->
            val name = "s-" + index.toString(16).padStart(32, '0')
            SyncDocument("$root/$name", name, true, 0)
        }
        check(lookup.find(root, "s-" + "0".repeat(32)) != null)
        check(runCatching { lookup.find(root, missing) }.exceptionOrNull()?.message ==
            "TOO_MANY_ENTRIES")
        provider.overrideRows = provider.overrideRows!! + SyncDocument(
            "$root/s-" + "f".repeat(32), "s-" + "f".repeat(32), true, 0)
        check(runCatching { lookup.find(root, "s-" + "0".repeat(32)) }.isFailure)
        check(provider.cursors.last().moves == DeviceSyncPolicy.MAX_ENTRIES + 1)
        check(provider.cursors.last().closed)
        provider.overrideRows = emptyList()
        provider.onMove = { owner.invalidate() }
        check(runCatching { lookup.find(root, missing) }.isFailure)
        check(provider.cursors.last().closed)
        provider.onMove = null
        val afterCancel = provider.queries.size
        check(runCatching { lookup.find(root, missing) }.isFailure)
        check(provider.queries.size == afterCancel)
        check(provider.documents == before)
        println("DeviceSyncSafDirectoryTest PASS bounded-parent-metadata/missing-child/overflow/identity/cancel")
    }
}

private class DirectoryProvider : ContentResolver() {
    val documents = mutableMapOf<String, SyncDocument>()
    val queries = mutableListOf<Uri>()
    val cursors = mutableListOf<DirectoryCursor>()
    var duplicate = false
    var virtual = false
    var failure: Exception? = null
    var nullCursor = false
    var overrideRows: List<SyncDocument>? = null
    var onMove: (() -> Unit)? = null
    override fun query(uri: Uri, projection: Array<String>?, selection: String?,
        selectionArgs: Array<String>?, sortOrder: String?, signal: CancellationSignal?): Cursor? {
        check(selection == null && selectionArgs == null && sortOrder == null)
        check(projection?.toList() == listOf("document_id", "_display_name", "mime_type", "_size", "flags"))
        check(signal != null && !signal.cancelled)
        queries.add(uri)
        failure?.let { throw it }
        if (nullCursor) return null
        val rows = overrideRows ?: if (uri.children) {
            documents.values.filter { it.id.substringBeforeLast('/') == uri.documentId }
        } else {
            listOf(documents[uri.documentId]
                ?: throw IllegalArgumentException("synthetic missing-child provider failure"))
        }
        val actual = if (duplicate && rows.isNotEmpty()) listOf(rows.first(), rows.first()) else rows
        return DirectoryCursor(actual, virtual, onMove).also { cursors.add(it) }
    }
}

private class DirectoryCursor(
    private val documents: List<SyncDocument>,
    private val virtual: Boolean,
    private val onMove: (() -> Unit)?,
) : Cursor {
    var moves = 0
    var closed = false
    private val document get() = documents[moves - 1]
    override fun moveToNext(): Boolean {
        moves++
        check(moves <= DeviceSyncPolicy.MAX_ENTRIES + 1) { "Unbounded directory query" }
        onMove?.invoke()
        return moves <= documents.size
    }
    override fun getString(column: Int): String = when (column) {
        0 -> document.id
        1 -> document.name
        2 -> if (document.directory) DocumentsContract.Document.MIME_TYPE_DIR else "application/octet-stream"
        else -> error("Invalid string column")
    }
    override fun getLong(column: Int): Long { check(column == 3); return document.size }
    override fun getInt(column: Int): Int {
        check(column == 4)
        return if (virtual) DocumentsContract.Document.FLAG_VIRTUAL_DOCUMENT else 0
    }
    override fun close() { closed = true }
}
