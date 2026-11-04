package android.content

import android.database.Cursor
import android.net.Uri
import android.os.CancellationSignal

abstract class ContentResolver {
    abstract fun query(uri: Uri, projection: Array<String>?, selection: String?,
        selectionArgs: Array<String>?, sortOrder: String?, signal: CancellationSignal?): Cursor?
}
