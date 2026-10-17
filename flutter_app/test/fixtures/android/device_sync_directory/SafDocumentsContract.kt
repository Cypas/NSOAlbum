package android.provider

import android.net.Uri

object DocumentsContract {
    fun buildDocumentUriUsingTree(tree: Uri, documentId: String): Uri {
        check(documentId.startsWith(tree.documentId + "/"))
        return Uri(documentId)
    }
    fun buildChildDocumentsUriUsingTree(tree: Uri, documentId: String): Uri {
        check(documentId == tree.documentId || documentId.startsWith(tree.documentId + "/"))
        return Uri(documentId, children = true)
    }
    fun getTreeDocumentId(tree: Uri) = tree.documentId
    object Document {
        const val COLUMN_DOCUMENT_ID = "document_id"
        const val COLUMN_DISPLAY_NAME = "_display_name"
        const val COLUMN_MIME_TYPE = "mime_type"
        const val COLUMN_SIZE = "_size"
        const val COLUMN_FLAGS = "flags"
        const val MIME_TYPE_DIR = "vnd.android.document/directory"
        const val FLAG_VIRTUAL_DOCUMENT = 512
    }
}
