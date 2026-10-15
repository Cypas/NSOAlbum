package io.github.cypas.nsoalbum

import android.os.Looper
import android.webkit.WebViewClient
import com.pichillilorenzo.flutter_inappwebview_android.InAppWebViewFlutterPlugin
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/** Completes destruction of an already-detached, plugin-owned SplatNet view. */
object SplatNetWebViewDisposal {
    fun register(engine: FlutterEngine) {
        MethodChannel(
            engine.dartExecutor.binaryMessenger,
            "io.github.cypas.nsoalbum/splatnet_webview",
        ).setMethodCallHandler { call, result ->
            if (call.method != "destroyKeepAlive") {
                result.notImplemented()
                return@setMethodCallHandler
            }
            try {
                check(Looper.myLooper() == Looper.getMainLooper())
                val id = call.argument<String>("keepAliveId")
                require(!id.isNullOrEmpty() && id.length <= 256)
                val plugin = engine.plugins.get(InAppWebViewFlutterPlugin::class.java)
                    as? InAppWebViewFlutterPlugin
                val manager = plugin?.inAppWebViewManager
                    ?: error("WebView manager unavailable")
                val owner = manager.keepAliveWebViews[id]
                    ?: error("WebView is not owned by this engine")
                val view = owner.webView ?: error("WebView already released")
                // Upstream removes channels, JavaScript, native handlers and the
                // parent first, but defers destroy() to about:blank completion.
                manager.disposeKeepAlive(id)
                view.stopLoading()
                view.webViewClient = WebViewClient()
                view.destroy()
                result.success(null)
            } catch (_: Exception) {
                result.error(
                    "SPLATNET_DISPOSE_FAILED",
                    "The embedded browser could not be closed safely.",
                    null,
                )
            }
        }
    }
}
