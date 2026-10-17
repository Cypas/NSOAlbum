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
        repeat(140) { sequence ->
            val name = "s-" + sequence.toString(16).padStart(32, '0')
            provider.documents["$root/$name"] = SyncDocument("$root/$name", name, true, 0)
        }
        val sessionParent = "$root/s-" + "0".repeat(32)
        provider.documents["$sessionParent/mobile"] = SyncDocument(
            "$sessionParent/mobile", "mobile", true, 0)
        val before = provider.documents.toMap()
        val first = lookup.find(root, "s-" + "0".repeat(32))
        check(first?.id == "$root/s-" + "0".repeat(32))
        val last = lookup.find(root, "s-0000000000000000000000000000008b")
        check(last?.name == "s-0000000000000000000000000000008b")
        check(lookup.find(root, "s-" + "e".repeat(32)) == null)
        check(lookup.find(sessionParent, "mobile")?.id == "$sessionParent/mobile")
        check(provider.documents == before)
        check(provider.queries == listOf(
            "$root/s-" + "0".repeat(32),
            "$root/s-0000000000000000000000000000008b",
            "$root/s-" + "e".repeat(32), "$sessionParent/mobile"))
        check(provider.cursors.all { it.moves <= 2 && it.closed })
        check(runCatching { lookup.find(root, "../escape") }.isFailure)
        check(provider.queries.size == 4)
        provider.duplicate = true
        check(runCatching { lookup.find(root, "s-" + "0".repeat(32)) }.isFailure)
        check(provider.cursors.last().moves == 2 && provider.cursors.last().closed)
        provider.duplicate = false
        provider.virtual = true
        check(runCatching { lookup.find(root, "s-" + "0".repeat(32)) }.isFailure)
        provider.virtual = false
        provider.failure = java.io.FileNotFoundException()
        check(lookup.find(root, "s-" + "e".repeat(32)) == null)
        provider.failure = SecurityException()
        check(runCatching { lookup.find(root, "s-" + "e".repeat(32)) }.isFailure)
        provider.failure = null
        owner.cancel()
        val calls = provider.queries.size
        check(runCatching { lookup.find(root, "s-" + "0".repeat(32)) }.isFailure)
        check(provider.queries.size == calls)
        println("DeviceSyncSafDirectoryTest PASS exact-id lookup/140 siblings/2-row bound/cancel")
    }
}

private class DirectoryProvider : ContentResolver() {
    val documents = mutableMapOf<String, SyncDocument>()
    val queries = mutableListOf<String>()
    val cursors = mutableListOf<DirectoryCursor>()
    var duplicate = false
    var virtual = false
    var failure: Exception? = null
    override fun query(uri: Uri, projection: Array<String>?, selection: String?,
        selectionArgs: Array<String>?, sortOrder: String?, signal: CancellationSignal?): Cursor {
        check(selection == null && selectionArgs == null && sortOrder == null)
        check(projection?.toList() == listOf("document_id", "_display_name", "mime_type", "_size", "flags"))
        check(signal != null && !signal.cancelled)
        queries.add(uri.documentId)
        failure?.let { throw it }
        return DirectoryCursor(documents[uri.documentId],
            if (duplicate) Int.MAX_VALUE else 1, virtual).also { cursors.add(it) }
    }
}
private class DirectoryCursor(
    private val document: SyncDocument?,
    private val repetitions: Int,
    private val virtual: Boolean,
) : Cursor {
    var moves = 0
    var closed = false
    override fun moveToNext(): Boolean {
        moves++
        check(moves <= 2) { "Directory lookup enumerated beyond a duplicate" }
        return document != null && moves <= repetitions
    }
    override fun getString(column: Int): String = when (column) {
        0 -> document!!.id
        1 -> document!!.name
        2 -> if (document!!.directory) DocumentsContract.Document.MIME_TYPE_DIR else "application/octet-stream"
        else -> error("Invalid string column")
    }
    override fun getLong(column: Int): Long { check(column == 3); return document!!.size }
    override fun getInt(column: Int): Int {
        check(column == 4)
        return if (virtual) DocumentsContract.Document.FLAG_VIRTUAL_DOCUMENT else 0
    }
    override fun close() { closed = true }
}
