package io.github.cypas.nsoalbum

import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.io.OutputStream

internal data class SyncDocument(val id: String, val name: String, val directory: Boolean, val size: Long)

internal interface SyncDocuments {
    fun children(parent: String): List<SyncDocument>
    fun stat(id: String): SyncDocument? =
        children(id.substringBeforeLast('/')).singleOrNull { it.id == id }
    fun findDirectory(parent: String, name: String): SyncDocument?
    fun create(parent: String, name: String, directory: Boolean): SyncDocument
    fun read(id: String): InputStream
    fun write(id: String): OutputStream
    fun rename(id: String, name: String): SyncDocument
    fun delete(id: String)
}
internal class DeviceSyncWindowFull : IllegalStateException("WINDOW_FULL")

internal class DeviceSyncMailbox(
    private val documents: SyncDocuments,
    private val root: String,
    private val operation: DeviceSyncOperation,
    private val metrics: DeviceSyncProviderMetrics? = null,
) {
    private inline fun <T> timed(step: DeviceSyncProviderMetrics.Step, bytes: Long = 0, action: () -> T): T {
        val started = System.nanoTime()
        var completedBytes = 0L
        try {
            return action().also { completedBytes = if (it is ByteArray) it.size.toLong() else bytes }
        } finally {
            metrics?.record(step, (System.nanoTime() - started).coerceAtLeast(0), completedBytes)
        }
    }
    private data class Receipt(val id: String, val length: Int)
    private val readReceipts = mutableMapOf<Pair<String, String>, Receipt>()
    private val nextAcknowledgement = mutableMapOf("desktop" to 0uL, "mobile" to 0uL)
    private val listings = mutableMapOf<String, MutableMap<String, SyncDocument>>()
    fun acknowledge(direction: String, name: String) {
        operation.check()
        DeviceSyncPolicy.direction(direction)
        require(DeviceSyncPolicy.blockName(name)) { "INVALID_BLOCK" }
        val sequence = name.substring(0, 16).toULong(16)
        val expected = nextAcknowledgement.getValue(direction)
        if (sequence < expected) return
        require(sequence < ULong.MAX_VALUE && sequence - expected < 8uL) { "INVALID_SEQUENCE" }
        val parent = folder(direction)
        // Preflight the entire consumed prefix before deleting any exchange file.
        // These are ciphertext cleanup receipts, not media or library completion.
        val nodes = (expected..sequence).map { value ->
            val block = value.toString(16).padStart(16, '0') + ".block"
            val receipt = readReceipts[direction to block] ?: error("BLOCK_NOT_READ")
            val node = timed(DeviceSyncProviderMetrics.Step.Properties) { documents.stat(receipt.id) }
                ?: error("BLOCK_NOT_FOUND")
            require(node.id == receipt.id && node.id == "$parent/$block" &&
                node.name == block && !node.directory &&
                (node.size == 0L || node.size == receipt.length.toLong())) { "BLOCK_CHANGED" }
            node
        }
        nodes.forEach { node ->
            operation.check()
            timed(DeviceSyncProviderMetrics.Step.Cleanup) { documents.delete(node.id) }
            readReceipts.remove(direction to node.name)
            listings[parent]?.remove(node.name)
            nextAcknowledgement[direction] = nextAcknowledgement.getValue(direction) + 1u
        }
    }
    private val session = directory(root, DeviceSyncPolicy.sessionDirectory(operation.session))
    private val folders = mutableMapOf<String, String>()
    private fun children(parent: String): List<SyncDocument> {
        operation.check()
        val entries = timed(DeviceSyncProviderMetrics.Step.Enumerate) { documents.children(parent) }
        require(entries.size <= DeviceSyncPolicy.MAX_ENTRIES) { "TOO_MANY_ENTRIES" }
        require(entries.map { it.name }.toSet().size == entries.size &&
            entries.map { it.id }.toSet().size == entries.size) { "DUPLICATE_DOCUMENT" }
        entries.forEach {
            require(it.id == "$parent/${it.name}" &&
                it.name.isNotEmpty() && !it.name.contains('/') && !it.name.contains('\\') &&
                it.name != "." && it.name != "..") { "INVALID_DOCUMENT" }
        }
        return entries
    }
    private fun directory(parent: String, name: String): String {
        operation.check()
        val node = timed(DeviceSyncProviderMetrics.Step.Enumerate) { documents.findDirectory(parent, name) }
            ?: timed(DeviceSyncProviderMetrics.Step.Create) { documents.create(parent, name, true) }
        require(node.directory && node.id == "$parent/$name" && node.name == name) { "INVALID_DIRECTORY" }
        return node.id
    }
    private fun folder(direction: String): String {
        operation.check()
        val valid = DeviceSyncPolicy.direction(direction)
        // Hold exact owner-scoped paths only for this session. If a directory is
        // removed, subsequent I/O must fail rather than create a replacement.
        return folders.getOrPut(valid) { directory(session, valid) }
    }
    private fun completeNodes(parent: String): List<SyncDocument> = children(parent).filter {
        if (it.name.endsWith(".part")) return@filter false
        require(DeviceSyncPolicy.blockName(it.name)) { "INVALID_BLOCK_NAME" }
        require(!it.directory) { "INVALID_BLOCK_TYPE" }
        // MTP rename may precede ExternalStorageProvider's size metadata.
        // Zero is provisional; read() checks the actual bounded byte stream.
        require(
            it.size == 0L ||
                it.size in 1..DeviceSyncPolicy.MAX_BLOCK.toLong(),
        ) { "INVALID_BLOCK_SIZE" }
        true
    }
    fun list(direction: String): List<String> {
        val parent = folder(direction)
        val nodes = completeNodes(parent)
        listings[parent] = nodes.associateBy { it.name }.toMutableMap()
        return nodes.map { it.name }.sorted()
    }

    fun read(direction: String, name: String): ByteArray {
        require(DeviceSyncPolicy.blockName(name)) { "INVALID_BLOCK" }
        val parent = folder(direction)
        val node = listings[parent]?.get(name) ?: run {
            list(direction)
            listings[parent]?.get(name)
        }
            ?: error("BLOCK_NOT_FOUND")
        val bytes = timed(DeviceSyncProviderMetrics.Step.PayloadRead) { readBytes(node) }
        require(bytes.size in 1..DeviceSyncPolicy.MAX_BLOCK &&
            (node.size == 0L || node.size == bytes.size.toLong())) {
            "INVALID_BLOCK_SIZE"
        }
        val key = direction to name
        require(readReceipts.containsKey(key) || readReceipts.size < DeviceSyncPolicy.MAX_ENTRIES) {
            "TOO_MANY_UNACKNOWLEDGED_BLOCKS"
        }
        val receipt = Receipt(node.id, bytes.size)
        require(readReceipts[key]?.let { it == receipt } != false) { "BLOCK_CHANGED" }
        readReceipts[key] = receipt
        return bytes
    }

    private fun readBytes(node: SyncDocument): ByteArray =
        documents.read(node.id).use { input ->
            operation.track(input)
            try {
                ByteArrayOutputStream().also {
                    DeviceSyncPolicy.copyBounded(input, it, operation)
                }.toByteArray()
            } finally { operation.untrack(input) }
        }

    fun write(name: String, bytes: ByteArray) {
        require(DeviceSyncPolicy.blockName(name) && bytes.size in 1..DeviceSyncPolicy.MAX_BLOCK) {
            "INVALID_BLOCK"
        }
        val parent = folder("mobile")
        var existing = listings[parent] ?: children(parent)
            .associateBy { it.name }.toMutableMap().also { listings[parent] = it }
        if (existing.size >= DeviceSyncPolicy.MAX_ENTRIES) {
            list("mobile")
            existing = listings.getValue(parent)
            if (existing.size >= DeviceSyncPolicy.MAX_ENTRIES) throw DeviceSyncWindowFull()
        }
        require(!existing.containsKey(name) && !existing.containsKey("$name.part")) { "BLOCK_EXISTS" }
        val partial = timed(DeviceSyncProviderMetrics.Step.Create) { documents.create(parent, "$name.part", false) }
        require(!partial.directory && partial.name == "$name.part" &&
            partial.id == "$parent/$name.part") { "INVALID_DOCUMENT" }
        timed(DeviceSyncProviderMetrics.Step.PayloadWrite, bytes.size.toLong()) {
            documents.write(partial.id).use { output ->
                operation.track(output)
                try { DeviceSyncPolicy.copyBounded(ByteArrayInputStream(bytes), output, operation) }
                finally { operation.untrack(output) }
            }
        }
        operation.check()
        val complete = timed(DeviceSyncProviderMetrics.Step.Rename) { documents.rename(partial.id, name) }
        operation.check()
        require(complete.id == "$parent/$name" && complete.name == name && !complete.directory) {
            "INVALID_DOCUMENT"
        }
        existing[name] = complete.copy(size = bytes.size.toLong())
    }
}
