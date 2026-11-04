package io.github.cypas.nsoalbum

import android.content.ContentResolver
import android.net.Uri
import android.os.CancellationSignal
import android.provider.DocumentsContract
import java.io.Closeable

/** Bounded parent metadata lookup; never opens or descends into historical sessions. */
internal class DeviceSyncSafDirectory(
    private val resolver: ContentResolver,
    private val tree: Uri,
    private val owner: DeviceSyncOperation,
) {
    fun find(parent: String, name: String): SyncDocument? {
        owner.check()
        val root = DocumentsContract.getTreeDocumentId(tree)
        val sessionPattern = Regex("s-[0-9a-f]{32}")
        require((parent == root && sessionPattern.matches(name)) ||
            (parent.startsWith("$root/") && sessionPattern.matches(parent.removePrefix("$root/")) &&
                (name == "desktop" || name == "mobile"))) { "INVALID_SCOPE" }
        val id = "$parent/$name"
        val signal = CancellationSignal()
        val closing = Closeable { signal.cancel() }
        owner.track(closing)
        try {
            val cursor = resolver.query(
                DocumentsContract.buildChildDocumentsUriUsingTree(tree, parent),
                arrayOf(DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                    DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                    DocumentsContract.Document.COLUMN_MIME_TYPE,
                    DocumentsContract.Document.COLUMN_SIZE, DocumentsContract.Document.COLUMN_FLAGS),
                null, null, null, signal,
            ) ?: error("DIRECTORY_UNAVAILABLE")
            return cursor.use {
                owner.check()
                var found: SyncDocument? = null
                var count = 0
                val ids = mutableSetOf<String>()
                val names = mutableSetOf<String>()
                while (cursor.moveToNext()) {
                    owner.check()
                    require(++count <= DeviceSyncPolicy.MAX_ENTRIES) { "TOO_MANY_ENTRIES" }
                    val node = SyncDocument(cursor.getString(0), cursor.getString(1),
                        cursor.getString(2) == DocumentsContract.Document.MIME_TYPE_DIR, cursor.getLong(3))
                    require(cursor.getInt(4) and DocumentsContract.Document.FLAG_VIRTUAL_DOCUMENT == 0 &&
                        node.name.isNotEmpty() && !node.name.contains('/') && !node.name.contains('\\') &&
                        node.name != "." && node.name != ".." && node.id == "$parent/${node.name}") {
                        "INVALID_DOCUMENT"
                    }
                    require(ids.add(node.id) && names.add(node.name)) { "DUPLICATE_DOCUMENT" }
                    if (node.name == name) {
                        require(node.id == id && node.directory) { "INVALID_DIRECTORY" }
                        found = node
                    }
                }
                owner.check()
                require(found != null || count < DeviceSyncPolicy.MAX_ENTRIES) { "TOO_MANY_ENTRIES" }
                found
            }
        } finally { owner.untrack(closing) }
    }
}
