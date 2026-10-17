package io.github.cypas.nsoalbum

import android.content.ContentResolver
import android.net.Uri
import android.os.CancellationSignal
import android.provider.DocumentsContract
import java.io.Closeable
import java.io.FileNotFoundException

/** Direct lookup under the exact external-storage tree; never enumerates historical sessions. */
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
            return resolver.query(
                DocumentsContract.buildDocumentUriUsingTree(tree, id),
                arrayOf(DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                    DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                    DocumentsContract.Document.COLUMN_MIME_TYPE,
                    DocumentsContract.Document.COLUMN_SIZE, DocumentsContract.Document.COLUMN_FLAGS),
                null, null, null, signal,
            )?.use { cursor ->
                owner.check()
                if (!cursor.moveToNext()) return@use null
                val node = SyncDocument(cursor.getString(0), cursor.getString(1),
                    cursor.getString(2) == DocumentsContract.Document.MIME_TYPE_DIR, cursor.getLong(3))
                require(cursor.getInt(4) and DocumentsContract.Document.FLAG_VIRTUAL_DOCUMENT == 0 &&
                    node.id == id && node.name == name && node.directory) { "INVALID_DIRECTORY" }
                require(!cursor.moveToNext()) { "DUPLICATE_DOCUMENT" }
                node
            }
        } catch (_: FileNotFoundException) {
            return null
        } finally { owner.untrack(closing) }
    }
}
