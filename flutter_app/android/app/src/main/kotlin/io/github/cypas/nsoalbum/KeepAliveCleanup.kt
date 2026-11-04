package io.github.cypas.nsoalbum

internal fun <T> retireKeepAliveEntry(
    registry: MutableMap<String, T?>,
    keepAliveId: String,
    dispose: (String) -> Unit,
) {
    if (!registry.containsKey(keepAliveId)) return
    try {
        dispose(keepAliveId)
    } finally {
        // flutter_inappwebview 6.1.5 leaves a null value in this map after
        // disposeKeepAlive. Its later plugin dispose iterates values assuming
        // they are non-null, which crashes FlutterActivity.onDestroy.
        registry.remove(keepAliveId)
    }
}
