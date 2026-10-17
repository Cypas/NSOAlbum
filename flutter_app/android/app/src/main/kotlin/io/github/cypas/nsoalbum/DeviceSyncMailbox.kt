package io.github.cypas.nsoalbum

import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream
import java.io.InputStream
import java.io.OutputStream
import java.security.MessageDigest

internal data class SyncDocument(val id: String, val name: String, val directory: Boolean, val size: Long)

internal interface SyncDocuments {
    fun children(parent: String): List<SyncDocument>
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
) {
    private data class Receipt(val id: String, val hash: ByteArray)
    private val readReceipts = mutableMapOf<Pair<String, String>, Receipt>()
    private val nextAcknowledgement = mutableMapOf("desktop" to 0uL, "mobile" to 0uL)
    fun acknowledge(direction: String, name: String) {
        operation.check()
        DeviceSyncPolicy.direction(direction)
        require(DeviceSyncPolicy.blockName(name)) { "INVALID_BLOCK" }
        val sequence = name.substring(0, 16).toULong(16)
        val expected = nextAcknowledgement.getValue(direction)
        if (sequence < expected) return
        require(sequence == expected && sequence < ULong.MAX_VALUE) { "INVALID_SEQUENCE" }
        val key = direction to name
        val receipt = readReceipts[key] ?: error("BLOCK_NOT_READ")
        val current = read(direction, name)
        require(MessageDigest.isEqual(receipt.hash, hash(current))) { "BLOCK_CHANGED" }
        val node = children(folder(direction)).single { it.name == name }
        require(node.id == receipt.id) { "BLOCK_CHANGED" }
        operation.check()
        documents.delete(node.id)
        readReceipts.remove(key)
        nextAcknowledgement[direction] = expected + 1u
    }
    private fun hash(bytes: ByteArray) = MessageDigest.getInstance("SHA-256").digest(bytes)
    private val session = directory(root, DeviceSyncPolicy.sessionDirectory(operation.session))
    private fun children(parent: String): List<SyncDocument> {
        operation.check()
        val entries = documents.children(parent)
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
        val node = documents.findDirectory(parent, name)
            ?: documents.create(parent, name, true)
        require(node.directory && node.id == "$parent/$name" && node.name == name) { "INVALID_DIRECTORY" }
        return node.id
    }
    private fun folder(direction: String) = directory(session, DeviceSyncPolicy.direction(direction))
    fun list(direction: String): List<String> = children(folder(direction)).filter {
        if (it.name.endsWith(".part")) return@filter false
        require(DeviceSyncPolicy.blockName(it.name) && !it.directory &&
            it.size in 1..DeviceSyncPolicy.MAX_BLOCK.toLong()) { "INVALID_BLOCK" }
        true
    }.map { it.name }.sorted()

    fun read(direction: String, name: String): ByteArray {
        require(DeviceSyncPolicy.blockName(name)) { "INVALID_BLOCK" }
        val parent = folder(direction)
        require(list(direction).contains(name)) { "BLOCK_NOT_FOUND" }
        val node = children(parent).single { it.name == name }
        val bytes = documents.read(node.id).use { input ->
            operation.track(input)
            try {
                ByteArrayOutputStream().also {
                    DeviceSyncPolicy.copyBounded(input, it, operation)
                }.toByteArray()
            } finally { operation.untrack(input) }
        }
        val key = direction to name
        require(readReceipts.containsKey(key) || readReceipts.size < DeviceSyncPolicy.MAX_ENTRIES) {
            "TOO_MANY_UNACKNOWLEDGED_BLOCKS"
        }
        readReceipts[key] = Receipt(node.id, hash(bytes))
        return bytes
    }

    fun write(name: String, bytes: ByteArray) {
        require(DeviceSyncPolicy.blockName(name) && bytes.size in 1..DeviceSyncPolicy.MAX_BLOCK) {
            "INVALID_BLOCK"
        }
        val parent = folder("mobile")
        val existing = children(parent)
        require(existing.none { it.name == name || it.name == "$name.part" }) { "BLOCK_EXISTS" }
        if (existing.size >= DeviceSyncPolicy.MAX_ENTRIES) throw DeviceSyncWindowFull()
        val partial = documents.create(parent, "$name.part", false)
        require(!partial.directory && partial.name == "$name.part" &&
            partial.id == "$parent/$name.part") { "INVALID_DOCUMENT" }
        documents.write(partial.id).use { output ->
            operation.track(output)
            try { DeviceSyncPolicy.copyBounded(ByteArrayInputStream(bytes), output, operation) }
            finally { operation.untrack(output) }
        }
        operation.check()
        require(children(parent).none { it.name == name }) { "BLOCK_EXISTS" }
        val complete = documents.rename(partial.id, name)
        operation.check()
        require(complete.id == "$parent/$name" && complete.name == name && !complete.directory) {
            "INVALID_DOCUMENT"
        }
    }
}
