package io.github.cypas.nsoalbum

import java.io.ByteArrayInputStream
import java.io.ByteArrayOutputStream

object DeviceSyncPolicyTest {
    @JvmStatic
    fun main(args: Array<String>) {
        var regressionsFailed = 0
        for ((name, regression) in listOf(
            "full window rejection preserves readable and acknowledgeable blocks" to ::fullWindow,
            "independent sessions do not exhaust the exchange root" to ::historicalSessions,
        )) {
            runCatching(regression).fold(
                { println("CAPACITY PASS $name") },
                { regressionsFailed++; println("CAPACITY FAIL $name: ${it.message}") },
            )
        }
        check(regressionsFailed == 0) { "$regressionsFailed capacity regressions failed" }
        diagnosticPrivacy()
        var checks = 0
        fun verify(value: Boolean) { check(value); checks++ }
        fun rejects(action: () -> Unit) = verify(runCatching(action).isFailure)
        val owners = DeviceSyncOwnerSlot()
        val firstScope = DeviceSyncOwnerScope("a".repeat(32), "b".repeat(32), "c".repeat(32))
        val firstOwner = owners.open(firstScope)
        val secondScope = DeviceSyncOwnerScope("d".repeat(32), "e".repeat(32), "f".repeat(32))
        verify(DeviceSyncPolicy.errorCode(runCatching { owners.open(secondScope) }
            .exceptionOrNull()!!) == "BUSY")
        verify(owners.retire(secondScope) == null)
        verify(owners.requireActive(firstScope) === firstOwner)
        for (wrong in listOf(
            firstScope.copy(operation = "0".repeat(32)),
            firstScope.copy(session = "0".repeat(32)),
            firstScope.copy(token = "0".repeat(32)),
        )) {
            rejects { owners.requireActive(wrong) }
            verify(owners.retire(wrong) == null)
            verify(owners.requireActive(firstScope) === firstOwner)
        }
        verify(owners.retire(firstScope) === firstOwner)
        rejects { firstOwner.check() }
        val reusedScope = firstScope.copy(token = "1".repeat(32))
        val reusedOwner = owners.open(reusedScope)
        verify(owners.retire(firstScope) == null)
        verify(owners.requireActive(reusedScope) === reusedOwner)
        verify(owners.invalidate() === reusedOwner)
        rejects { reusedOwner.check() }
        verify(owners.operation == null)
        rejects { DeviceSyncOwnerScope("a".repeat(32), "b".repeat(32), "../token") }
        val ioSlot = DeviceSyncIoSlot()
        ioSlot.begin()
        verify(DeviceSyncPolicy.errorCode(runCatching { ioSlot.begin() }.exceptionOrNull()!!) == "BUSY")
        // A cancel notification does not retire the still-running OS call.
        rejects { ioSlot.requireIdle() }
        ioSlot.beginClose()
        ioSlot.finished()
        rejects { ioSlot.begin() }
        ioSlot.finishedClose()
        ioSlot.begin()
        ioSlot.finished()
        verify(DeviceSyncPolicy.errorCode(DeviceSyncDirectoryDenied()) == "DIRECTORY_NOT_AUTHORIZED")
        verify(DeviceSyncPolicy.errorCode(SecurityException("private-uri")) == "DIRECTORY_NOT_AUTHORIZED")
        verify(DeviceSyncPolicy.errorCode(IllegalArgumentException("private-name")) == "INVALID_BLOCK")
        verify(DeviceSyncPolicy.errorCode(java.io.IOException("private-path")) == "DEVICE_SYNC_UNAVAILABLE")
        val session = "0123456789abcdef0123456789abcdef"
        verify(DeviceSyncPolicy.sessionDirectory(session) == "s-$session")
        for (bad in listOf("", "../$session", session.uppercase(), "$session/", "a".repeat(33))) {
            rejects { DeviceSyncPolicy.sessionDirectory(bad) }
        }
        verify(DeviceSyncPolicy.exactTree("com.android.externalstorage.documents",
            "primary:Documents/NSOAlbumSync"))
        for ((authority, id) in listOf(
            "other" to "primary:Documents/NSOAlbumSync",
            "com.android.externalstorage.documents" to "primary:Documents",
            "com.android.externalstorage.documents" to "primary:Documents/NSOAlbumSync/child",
            "com.android.externalstorage.documents" to "primary:Documents/../NSOAlbumSync",
        )) verify(!DeviceSyncPolicy.exactTree(authority, id))
        verify(DeviceSyncPolicy.blockName("0000000000000000.block"))
        for (bad in listOf("../0000000000000000.block", "000000000000000A.block",
            "0000000000000000.block.part", "0000000000000000.block/")) {
            verify(!DeviceSyncPolicy.blockName(bad))
        }
        val operation = DeviceSyncOperation("a".repeat(32), session)
        val output = ByteArrayOutputStream()
        DeviceSyncPolicy.copyBounded(ByteArrayInputStream(byteArrayOf(1, 2, 3)), output, operation)
        verify(output.toByteArray().contentEquals(byteArrayOf(1, 2, 3)))
        rejects { DeviceSyncPolicy.copyBounded(ByteArrayInputStream(ByteArray(65549)),
            ByteArrayOutputStream(), operation) }
        rejects { DeviceSyncPolicy.copyBounded(ByteArrayInputStream(byteArrayOf()),
            ByteArrayOutputStream(), operation) }
        operation.cancel()
        rejects { operation.requireActive("a".repeat(32), session) }
        rejects { DeviceSyncPolicy.copyBounded(ByteArrayInputStream(byteArrayOf(1)),
            ByteArrayOutputStream(), operation) }
        val next = DeviceSyncOperation("b".repeat(32), session)
        rejects { next.requireActive("a".repeat(32), session) }
        rejects { next.requireActive("b".repeat(32), "c".repeat(32)) }
        val documents = MemoryDocuments()
        val mailbox = DeviceSyncMailbox(documents, "primary:Documents/NSOAlbumSync", next)
        mailbox.write("0000000000000000.block", byteArrayOf(7, 8, 9))
        verify(mailbox.list("mobile") == listOf("0000000000000000.block"))
        verify(mailbox.read("mobile", "0000000000000000.block").contentEquals(byteArrayOf(7, 8, 9)))
        rejects { mailbox.write("0000000000000000.block", byteArrayOf(5)) }
        verify(mailbox.read("mobile", "0000000000000000.block").contentEquals(byteArrayOf(7, 8, 9)))
        rejects { mailbox.list("../desktop") }
        val parent = "primary:Documents/NSOAlbumSync/s-$session/mobile"
        documents.nodes.add(SyncDocument("$parent/0000000000000001.block.part",
            "0000000000000001.block.part", false, 0))
        verify(mailbox.list("mobile").size == 1)
        documents.nodes.add(SyncDocument("$parent/duplicate",
            "0000000000000000.block", false, 3))
        rejects { mailbox.list("mobile") }
        documents.nodes.removeAt(documents.nodes.lastIndex)
        documents.nodes.add(SyncDocument("outside", "0000000000000002.block", false, 3))
        documents.injectOutside = true
        rejects { mailbox.list("mobile") }
        documents.injectOutside = false
        next.cancel()
        rejects { mailbox.write("0000000000000002.block", byteArrayOf(4)) }
        val picker = DeviceSyncPicker<String>()
        picker.begin("first")
        verify(picker.cancel() == "first")
        rejects { picker.begin("second") }
        verify(picker.complete() == null)
        picker.begin("second")
        verify(picker.complete() == "second")
        verify(picker.complete() == null)
        val streamingDocuments = MemoryDocuments()
        val streamingOwner = DeviceSyncOperation("d".repeat(32), "e".repeat(32))
        val streaming = DeviceSyncMailbox(streamingDocuments, "primary:Documents/NSOAlbumSync", streamingOwner)
        for (sequence in 0 until 140) {
            val name = sequence.toString(16).padStart(16, '0') + ".block"
            streaming.write(name, byteArrayOf(4, 5, 6))
            rejects { streaming.acknowledge("mobile", name) }
            verify(streaming.read("mobile", name).contentEquals(byteArrayOf(4, 5, 6)))
            streaming.acknowledge("mobile", name)
            streaming.acknowledge("mobile", name)
            verify(streaming.list("mobile").isEmpty())
        }
        rejects { streaming.acknowledge("mobile", "../0000000000000000.block") }
        streamingOwner.cancel()
        rejects { streaming.acknowledge("mobile", "0000000000000000.block") }
        println("DeviceSyncPolicyTest PASS $checks checks")
    }

    private fun diagnosticPrivacy() {
        check(DeviceSyncPolicy.diagnostic("openSession", IllegalArgumentException("INVALID_DIRECTORY")) ==
            "device_sync_saf method=openSession category=InvalidArgument reason=INVALID_DIRECTORY code=INVALID_BLOCK")
        for (privateValue in listOf(
            "content://private/tree/private?token=synthetic-secret",
            "INVALID_DIRECTORY\nprivate-document-id",
            "private-scope private-account private-name",
        )) {
            check(DeviceSyncPolicy.diagnostic(privateValue, IllegalArgumentException(privateValue)) ==
                "device_sync_saf method=other category=InvalidArgument reason=other code=INVALID_BLOCK")
            check(DeviceSyncPolicy.diagnostic("readBlock", java.io.IOException(privateValue)) ==
                "device_sync_saf method=readBlock category=Io reason=other code=DEVICE_SYNC_UNAVAILABLE")
        }
    }

    private fun fullWindow() {
        val documents = MemoryDocuments()
        val owner = DeviceSyncOperation("a".repeat(32), "b".repeat(32))
        val mailbox = DeviceSyncMailbox(documents, "primary:Documents/NSOAlbumSync", owner)
        repeat(128) { sequence ->
            mailbox.write(sequence.toString(16).padStart(16, '0') + ".block", byteArrayOf(1, 2, 3))
        }
        check(mailbox.read("mobile", "0000000000000000.block").contentEquals(byteArrayOf(1, 2, 3)))
        val before = documents.nodes.toList()
        check(runCatching {
            mailbox.write("0000000000000080.block", byteArrayOf(4))
        }.exceptionOrNull() is DeviceSyncWindowFull)
        check(documents.nodes == before) { "Rejected write changed the full directory" }
        check(mailbox.list("mobile").size == 128)
        check(mailbox.read("mobile", "0000000000000000.block").contentEquals(byteArrayOf(1, 2, 3)))
        mailbox.acknowledge("mobile", "0000000000000000.block")
        check(mailbox.list("mobile").size == 127)
        mailbox.write("0000000000000080.block", byteArrayOf(4))
        check(mailbox.list("mobile").size == 128)
        check(mailbox.read("mobile", "0000000000000080.block").contentEquals(byteArrayOf(4)))
        owner.cancel()
    }

    private fun historicalSessions() {
        val documents = MemoryDocuments()
        val root = "primary:Documents/NSOAlbumSync"
        repeat(140) { sequence ->
            val session = sequence.toString(16).padStart(32, '0')
            val owner = DeviceSyncOperation("f".repeat(32), session)
            check(DeviceSyncMailbox(documents, root, owner).list("mobile").isEmpty())
            owner.cancel()
        }
        val previous = documents.nodes.toList()
        val first = DeviceSyncOperation("e".repeat(32), "0".repeat(32))
        check(DeviceSyncMailbox(documents, root, first).list("mobile").isEmpty())
        check(documents.nodes == previous) { "Reopen changed historical sessions" }
        first.cancel()
        val next = DeviceSyncOperation("d".repeat(32), "c".repeat(32))
        check(DeviceSyncMailbox(documents, root, next).list("mobile").isEmpty())
        check(documents.nodes.containsAll(previous)) { "Opening a new session removed history" }
        next.cancel()
    }
}

private class MemoryDocuments : SyncDocuments {
    val nodes = mutableListOf<SyncDocument>()
    val bytes = mutableMapOf<String, ByteArray>()
    var injectOutside = false
    override fun children(parent: String) = nodes.filter {
        it.id.substringBeforeLast('/') == parent || (injectOutside && it.id == "outside")
    }
    override fun findDirectory(parent: String, name: String) =
        nodes.filter { it.id == "$parent/$name" }.singleOrNull()
    override fun create(parent: String, name: String, directory: Boolean): SyncDocument =
        SyncDocument("$parent/$name", name, directory, 0).also { nodes.add(it) }
    override fun read(id: String) = ByteArrayInputStream(bytes.getValue(id))
    override fun write(id: String) = object : ByteArrayOutputStream() {
        override fun close() {
            bytes[id] = toByteArray()
            val index = nodes.indexOfFirst { it.id == id }
            nodes[index] = nodes[index].copy(size = size().toLong())
        }
    }
    override fun rename(id: String, name: String): SyncDocument {
        val index = nodes.indexOfFirst { it.id == id }
        val node = nodes[index].copy(id = "${id.substringBeforeLast('/')}/$name", name = name)
        nodes[index] = node
        bytes[node.id] = bytes.remove(id)!!
        return node
    }
    override fun delete(id: String) {
        nodes.removeAt(nodes.indexOfFirst { it.id == id })
        bytes.remove(id)
    }
}
