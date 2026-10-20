package io.github.cypas.nsoalbum

import android.app.Activity
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.net.Uri
import android.os.CancellationSignal
import android.os.Handler
import android.os.Looper
import android.provider.DocumentsContract
import android.util.Log
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.Closeable
import java.util.concurrent.Executors

/** Opaque byte mailbox only. This channel never opens CoreApi, account storage, or the media library. */
internal class DeviceSyncSafChannel(
    private val activity: Activity,
    private val channel: MethodChannel,
) : Closeable {
    companion object { const val REQUEST_TREE = 9241 }
    private val main = Handler(Looper.getMainLooper())
    private val io = Executors.newSingleThreadExecutor()
    private val preferences = activity.getSharedPreferences("device_sync_directory", Activity.MODE_PRIVATE)
    private val picker = DeviceSyncPicker<MethodChannel.Result>()
    private val owners = DeviceSyncOwnerSlot()
    private val operation get() = owners.operation
    private var pickerToken: String? = null
    private var mailbox: DeviceSyncMailbox? = null
    private var providerMetrics: DeviceSyncProviderMetrics? = null
    private var pending: MethodChannel.Result? = null
    private var destroyed = false
    private var epoch = 0L
    private val ioSlot = DeviceSyncIoSlot()

    init { channel.setMethodCallHandler(::handle) }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
        if (destroyed) return result.error("OPERATION_CLOSED", null, null)
        try {
            when (call.method) {
                "selectTree" -> {
                    ioSlot.requireIdle()
                    if (picker.outstanding || pending != null || operation != null) throw DeviceSyncIoBusy()
                    val token = call.argument<String>("pickerToken") ?: error("INVALID_SCOPE")
                    DeviceSyncPolicy.sessionDirectory(token)
                    val reusable = try { authorizedTree(); true }
                        catch (_: DeviceSyncDirectoryDenied) { false }
                        catch (_: SecurityException) { false }
                    if (!picker.beginIfNeeded(result, reusable)) {
                        result.success(true)
                        return
                    }
                    pickerToken = token
                    val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).addFlags(
                        Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION or
                            Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION or Intent.FLAG_GRANT_PREFIX_URI_PERMISSION)
                    intent.putExtra(DocumentsContract.EXTRA_INITIAL_URI,
                        DocumentsContract.buildDocumentUri("com.android.externalstorage.documents",
                            "primary:Documents/NSOAlbumSync"))
                    try {
                        activity.startActivityForResult(intent, REQUEST_TREE)
                    } catch (failure: Exception) {
                        picker.complete()
                        pickerToken = null
                        throw failure
                    }
                }
                "cancel", "close" -> {
                    val args = call.arguments as? Map<*, *> ?: error("INVALID_SCOPE")
                    val token = args["pickerToken"] as? String
                    if (token != null) {
                        if (pickerToken == token) {
                            pickerToken = null
                            picker.cancel()?.error("OPERATION_CLOSED", null, null)
                        }
                    } else {
                        invalidate(scope = ownerScope(args))
                    }
                    result.success(null)
                }
                "revoke" -> {
                    invalidate()
                    storedTree()?.let { activity.contentResolver.releasePersistableUriPermission(it,
                        Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION) }
                    preferences.edit().remove("tree").apply()
                    result.success(null)
                }
                "openSession" -> {
                    ioSlot.requireIdle()
                    if (picker.outstanding) throw DeviceSyncIoBusy()
                    val args = call.arguments as? Map<*, *> ?: error("INVALID_SCOPE")
                    val owner = owners.open(ownerScope(args))
                    providerMetrics = DeviceSyncProviderMetrics()
                    execute(owner, result, call.method) {
                        val tree = authorizedTree()
                        mailbox = DeviceSyncMailbox(AndroidDocuments(tree, owner),
                            DocumentsContract.getTreeDocumentId(tree), owner, providerMetrics)
                        true
                    }
                }
                "listBlocks", "readBlock", "writeCiphertextBlock", "acknowledgeBlock" -> {
                    val args = call.arguments as? Map<*, *> ?: error("INVALID_SCOPE")
                    val owner = owners.requireActive(ownerScope(args))
                    val inputBytes = (args["bytes"] as? ByteArray)?.size ?: 0
                    execute(owner, result, call.method, inputBytes) {
                        authorizedTree()
                        val box = mailbox ?: error("OPERATION_CLOSED")
                        when (call.method) {
                            "listBlocks" -> box.list(args["direction"] as String)
                            "readBlock" -> box.read(args["direction"] as String, args["name"] as String)
                            "acknowledgeBlock" -> {
                                box.acknowledge(args["direction"] as String, args["name"] as String)
                                null
                            }
                            else -> {
                                box.write(args["name"] as String, args["bytes"] as ByteArray)
                                null
                            }
                        }
                    }
                }
                else -> result.notImplemented()
            }
        } catch (failure: Exception) {
            debugFailure(call.method, failure)
            result.error(DeviceSyncPolicy.errorCode(failure), null, null)
        }
    }

    private fun debugFailure(method: String, failure: Throwable) {
        if ((activity.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0) {
            Log.e("NSOAlbumDeviceSync", DeviceSyncPolicy.diagnostic(method, failure))
        }
    }

    private fun ownerScope(args: Map<*, *>) = DeviceSyncOwnerScope(
        args["operationId"] as? String ?: throw IllegalArgumentException("INVALID_SCOPE"),
        args["sessionId"] as? String ?: throw IllegalArgumentException("INVALID_SCOPE"),
        args["ownerToken"] as? String ?: throw IllegalArgumentException("INVALID_SCOPE"),
    )

    private fun execute(
        owner: DeviceSyncOperation,
        result: MethodChannel.Result,
        method: String,
        inputBytes: Int = 0,
        action: () -> Any?,
    ) {
        check(pending == null) { "BUSY" }
        ioSlot.begin()
        pending = result
        val generation = epoch
        // Capture the exact owner instance. A retired worker must not mutate the next session.
        val timing = providerMetrics
        val kind = when (method) {
            "listBlocks" -> DeviceSyncProviderMetrics.Kind.List
            "readBlock" -> DeviceSyncProviderMetrics.Kind.Read
            "writeCiphertextBlock" -> DeviceSyncProviderMetrics.Kind.Write
            "acknowledgeBlock" -> DeviceSyncProviderMetrics.Kind.Acknowledge
            else -> null
        }
        val deadline = Runnable {
            if (pending === result && operation === owner && epoch == generation) {
                if ((activity.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0) {
                    Log.e("NSOAlbumDeviceSync", "device_sync_saf method=$method category=Deadline reason=TIMEOUT code=TIMEOUT")
                }
                invalidate("TIMEOUT")
            }
        }
        main.postDelayed(deadline, 30_000)
        io.execute {
            kind?.let { timing?.begin(it, System.nanoTime()) }
            if (method == "acknowledgeBlock" &&
                (activity.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0) {
                Log.e("NSOAlbumDeviceSync", "device_sync_ack phase=workerBegin")
            }
            val answer = runCatching { owner.check(); action().also { owner.check() } }
            if (kind != null) {
                val bytes = if (answer.isFailure) 0 else when (kind) {
                    DeviceSyncProviderMetrics.Kind.Read -> (answer.getOrNull() as? ByteArray)?.size ?: 0
                    DeviceSyncProviderMetrics.Kind.Write -> inputBytes
                    else -> 0
                }
                timing?.end(System.nanoTime(), answer.isFailure, bytes)
            }
            if (method == "acknowledgeBlock" &&
                (activity.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE) != 0) {
                Log.e("NSOAlbumDeviceSync", "device_sync_ack phase=workerEnd")
            }
            main.post {
                ioSlot.finished()
                main.removeCallbacks(deadline)
                if (!destroyed && epoch == generation && operation === owner && pending === result) {
                    pending = null
                    answer.fold(result::success) {
                        debugFailure(method, it)
                        val code = DeviceSyncPolicy.errorCode(it)
                        if (it is DeviceSyncWindowFull) {
                            result.error(code, null, null)
                        } else {
                            invalidate()
                            result.error(code, null, null)
                        }
                    }
                }
            }
        }
    }

    fun onActivityResult(request: Int, code: Int, data: Intent?): Boolean {
        if (request != REQUEST_TREE) return false
        val result = picker.complete()
        pickerToken = null
        if (result == null) return true
        if (destroyed || code != Activity.RESULT_OK || data?.data == null) {
            result.error("DIRECTORY_NOT_AUTHORIZED", null, null)
            return true
        }
        try {
            val tree = data.data!!
            require(DeviceSyncPolicy.exactTree(tree.authority, DocumentsContract.getTreeDocumentId(tree)))
            val flags = data.flags and (Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
            require(flags == (Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION))
            activity.contentResolver.takePersistableUriPermission(tree, flags)
            preferences.edit().putString("tree", tree.toString()).apply()
            result.success(true)
        } catch (failure: Exception) {
            debugFailure("selectTree", failure)
            result.error("DIRECTORY_NOT_AUTHORIZED", "Select Documents/NSOAlbumSync only.", null)
        }
        return true
    }

    private fun storedTree(): Uri? = preferences.getString("tree", null)?.let(Uri::parse)
    private fun authorizedTree(): Uri {
        val tree = storedTree() ?: throw DeviceSyncDirectoryDenied()
        if (!DeviceSyncPolicy.exactTree(tree.authority, DocumentsContract.getTreeDocumentId(tree))) {
            throw DeviceSyncDirectoryDenied()
        }
        if (!activity.contentResolver.persistedUriPermissions.any {
            it.uri == tree && it.isReadPermission && it.isWritePermission
        }) throw DeviceSyncDirectoryDenied()
        return tree
    }
    private fun invalidate(code: String = "OPERATION_CLOSED", scope: DeviceSyncOwnerScope? = null) {
        val owner = if (scope == null) owners.invalidate() else {
            owners.retire(scope) ?: return
        }
        epoch++
        mailbox = null
        providerMetrics?.let {
            Log.i("NSOAlbumDeviceSync", it.finish(System.nanoTime()))
        }
        providerMetrics = null
        // Closing a provider pipe can block; invalidate on main, close native handles off main.
        owner?.let {
            ioSlot.beginClose()
            ioClose.execute { try { it.cancel() } finally { ioSlot.finishedClose() } }
        }
        if (scope == null) {
            pickerToken = null
            picker.cancel()?.error(code, null, null)
        }
        pending?.error(code, null, null)
        pending = null
    }
    private val ioClose = Executors.newSingleThreadExecutor()
    override fun close() {
        destroyed = true
        invalidate()
        channel.setMethodCallHandler(null)
        io.shutdownNow()
        ioClose.shutdown()
    }

    private inner class AndroidDocuments(private val tree: Uri, private val owner: DeviceSyncOperation) : SyncDocuments {
        private val resolver = activity.contentResolver
        private fun uri(id: String) = DocumentsContract.buildDocumentUriUsingTree(tree, id)
        override fun findDirectory(parent: String, name: String): SyncDocument? =
            DeviceSyncSafDirectory(resolver, tree, owner).find(parent, name)
        override fun stat(id: String): SyncDocument? {
            owner.check()
            val signal = CancellationSignal()
            val closing = Closeable { signal.cancel() }
            owner.track(closing)
            try {
                return resolver.query(uri(id), arrayOf(
                    DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                    DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                    DocumentsContract.Document.COLUMN_MIME_TYPE,
                    DocumentsContract.Document.COLUMN_SIZE,
                    DocumentsContract.Document.COLUMN_FLAGS), null, null, null, signal)?.use { cursor ->
                    if (!cursor.moveToFirst()) return@use null
                    require(cursor.getInt(4) and DocumentsContract.Document.FLAG_VIRTUAL_DOCUMENT == 0)
                    val node = SyncDocument(cursor.getString(0), cursor.getString(1),
                        cursor.getString(2) == DocumentsContract.Document.MIME_TYPE_DIR, cursor.getLong(3))
                    require(!cursor.moveToNext()) { "DUPLICATE_DOCUMENT" }
                    node
                }
            } finally { owner.untrack(closing) }
        }
        override fun children(parent: String): List<SyncDocument> {
            val signal = CancellationSignal()
            val closing = Closeable { signal.cancel() }
            owner.track(closing)
            try {
                val children = DocumentsContract.buildChildDocumentsUriUsingTree(tree, parent)
                return resolver.query(children, arrayOf(
                    DocumentsContract.Document.COLUMN_DOCUMENT_ID, DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                    DocumentsContract.Document.COLUMN_MIME_TYPE, DocumentsContract.Document.COLUMN_SIZE,
                    DocumentsContract.Document.COLUMN_FLAGS), null, null, null, signal)?.use { cursor ->
                    val found = mutableListOf<SyncDocument>()
                    while (cursor.moveToNext()) {
                        owner.check()
                        require(found.size < DeviceSyncPolicy.MAX_ENTRIES) { "TOO_MANY_ENTRIES" }
                        require(cursor.getInt(4) and DocumentsContract.Document.FLAG_VIRTUAL_DOCUMENT == 0)
                        found.add(SyncDocument(cursor.getString(0), cursor.getString(1),
                            cursor.getString(2) == DocumentsContract.Document.MIME_TYPE_DIR, cursor.getLong(3)))
                    }
                    found
                } ?: error("DIRECTORY_UNAVAILABLE")
            } finally { owner.untrack(closing) }
        }
        override fun create(parent: String, name: String, directory: Boolean): SyncDocument {
            owner.check()
            val created = DocumentsContract.createDocument(resolver, uri(parent),
                if (directory) DocumentsContract.Document.MIME_TYPE_DIR else "application/octet-stream", name)
                ?: error("CREATE_FAILED")
            return SyncDocument(DocumentsContract.getDocumentId(created), name, directory, 0)
        }
        override fun read(id: String) = resolver.openInputStream(uri(id)) ?: error("READ_FAILED")
        override fun write(id: String) = resolver.openOutputStream(uri(id), "wt") ?: error("WRITE_FAILED")
        override fun rename(id: String, name: String): SyncDocument {
            owner.check()
            val renamed = DocumentsContract.renameDocument(resolver, uri(id), name) ?: error("PUBLISH_FAILED")
            return SyncDocument(DocumentsContract.getDocumentId(renamed), name, false, 0)
        }
        override fun delete(id: String) {
            owner.check()
            check(DocumentsContract.deleteDocument(resolver, uri(id))) { "ACKNOWLEDGEMENT_FAILED" }
        }
    }
}
