import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../backend/app_backend.dart';
import '../../backend/account_tool_lifecycle.dart';
import '../../backend/nintendo_account_tools_backend.dart';
import '../../l10n/app_localizations.dart';
import '../../platform/splatnet_mac_network.dart';
import '../../platform/splatnet_tls_policy.dart';
import '../../platform/splatnet_windows_environment.dart';
import '../../rust/models.dart';
import 'account_tool_errors.dart';
import 'account_tool_frame.dart';
import 'account_tool_operation.dart';
import 'native_webview_lifecycle.dart';
import 'splatnet_policy.dart';
import 'splatnet_close.dart';
import 'splatnet_profile_cleanup.dart';
import 'splatnet_request_gate.dart';
import 'web_resource_lifecycle.dart';

bool _browserOpen = false;
Future<void> _browserCleanup = Future<void>.value();

Future<void> openSplatNetPage(
  BuildContext context, {
  required AppBackend backend,
  required NintendoAccountProfile profile,
  required bool mobile,
}) async {
  if (_browserOpen || backend is! NintendoAccountToolsBackend) return;
  _browserOpen = true;
  try {
    await _browserCleanup;
    if (!context.mounted) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => SplatNetBrowserPage(
          backend: backend,
          profile: profile,
          mobile: mobile,
        ),
      ),
    );
    await _browserCleanup;
  } finally {
    _browserOpen = false;
  }
}

class SplatNetBrowserPage extends StatefulWidget {
  const SplatNetBrowserPage({
    super.key,
    required this.backend,
    required this.profile,
    required this.mobile,
  });
  final AppBackend backend;
  final NintendoAccountProfile profile;
  final bool mobile;
  @override
  State<SplatNetBrowserPage> createState() => _SplatNetBrowserPageState();
}

class _SplatNetBrowserPageState extends State<SplatNetBrowserPage> {
  NintendoAccountToolsBackend get tools =>
      widget.backend as NintendoAccountToolsBackend;
  InAppWebViewController? web;
  SplatNetWindowsEnvironment? environment;
  Directory? profileDirectory;
  String? profileParent;
  SplatNetPageLease? lease;
  SplatNetWebSession? session;
  Uri? entryUrl;
  Object? error;
  String? operationId;
  String? proxyAtCreation;
  bool initialized = false;
  bool ready = false;
  bool nativeVisible = false;
  bool leaving = false;
  bool allowPop = false;
  bool macConfigured = false;
  final sessionRequests = SplatNetRequestGate();
  int document = 0;
  int progress = 0;
  Future<void>? cleanup;
  WebResourceLifecycle resources = WebResourceLifecycle();
  NativeWebViewLifecycle nativeView = NativeWebViewLifecycle();
  bool preparing = false;
  AccountToolLifecycle? lifecycleEvents;
  AccountCleanupRegistration? credentialCleanup;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!initialized) {
      initialized = true;
      final backend = widget.backend;
      if (backend is NintendoAccountToolLifecycleBackend) {
        lifecycleEvents = (backend as NintendoAccountToolLifecycleBackend)
            .accountToolLifecycle;
        lifecycleEvents!.addListener(onPolicyChanged);
        credentialCleanup = lifecycleEvents!.registerCleanup(
          widget.profile.accountId,
          closeResources,
        );
      }
      unawaited(prepare());
    }
  }

  bool get valid =>
      mounted &&
      !leaving &&
      resources.active &&
      lease?.validFor(widget.profile.accountId) == true;

  void onPolicyChanged() {
    if (lifecycleEvents?.isRemoved(widget.profile.accountId) == true) {
      unawaited(fail(StateError('account_tool_sign_in_required')));
    } else if (!Platform.isAndroid &&
        initialized &&
        widget.backend.settings.proxyUrl != proxyAtCreation) {
      unawaited(fail(StateError('splatnet_proxy_changed')));
    }
  }

  Future<SplatNetWebSession> fetchSession({bool force = false}) async {
    final id = accountToolOperationId('splatnet');
    operationId = id;
    try {
      final result = await tools.prepareSplatNetSession(
        widget.profile.accountId,
        id,
        forceRefresh: force,
      );
      if (!valid || operationId != id) {
        throw StateError('account_tool_cancelled');
      }
      return result;
    } finally {
      if (operationId == id) operationId = null;
    }
  }

  Future<void> prepare() async {
    if (preparing || leaving) return;
    preparing = true;
    try {
      await (cleanup ?? Future<void>.value());
      if (!mounted || leaving) return;
      if (lifecycleEvents?.isRemoved(widget.profile.accountId) == true) {
        throw StateError('account_tool_sign_in_required');
      }
      cleanup = null;
      resources = WebResourceLifecycle();
      nativeView = NativeWebViewLifecycle();
      setState(() {
        error = null;
        ready = false;
      });
      lease = SplatNetPageLease.acquire(widget.profile.accountId);
      await resources.initialize(prepareResources);
    } catch (failure) {
      if (mounted && !leaving) {
        setState(() {
          error = failure;
          ready = false;
        });
      }
      try {
        await closeResources();
      } catch (_) {
        // Retain the failed cleanup future, preventing an unsafe retry.
      }
    } finally {
      preparing = false;
    }
  }

  Future<void> prepareResources() async {
    final language = context.l10n.locale.languageCode;
    // Plugin event/evaluation logs can contain credentials or private content.
    PlatformInAppWebViewController.debugLoggingSettings.enabled = false;
    proxyAtCreation = widget.backend.settings.proxyUrl;
    final config = SplatNetProxyConfiguration.resolve(
      platform: Platform.operatingSystem,
      proxyUrl: proxyAtCreation,
    );
    if (Platform.isWindows) {
      if ((await WebViewEnvironment.getAvailableVersion())?.isNotEmpty !=
          true) {
        throw UnsupportedError('webview2_unavailable');
      }
      if (!valid) return;
      final cache = await getApplicationCacheDirectory();
      if (!valid) return;
      final parent = Directory(p.join(cache.path, 'splatnet-webview'));
      await parent.create(recursive: true);
      if (!valid) return;
      profileParent = parent.absolute.path;
      profileDirectory = await parent.createTemp('session-');
      if (!valid) return;
      environment = await SplatNetWindowsEnvironment.create(
        settings: WebViewEnvironmentSettings(
          userDataFolder: profileDirectory!.path,
          additionalBrowserArguments: config.windowsArguments,
        ),
      );
    } else if (Platform.isMacOS) {
      await SplatNetMacNetwork.configure(config.proxy);
      macConfigured = true;
    } else if (Platform.isAndroid) {
      await clearAndroidSite();
    } else {
      throw UnsupportedError('webview_platform_unavailable');
    }
    if (!valid) return;
    session = await fetchSession(force: false);
    if (valid) {
      entryUrl = SplatNetPolicy.entryUrl(language, session!.country);
      setState(() {
        ready = true;
        nativeVisible = true;
        error = null;
      });
    }
  }

  Future<void> clearAndroidSite() async {
    final manager = CookieManager.instance();
    final uri = WebUri(SplatNetPolicy.origin);
    for (final cookie in await manager.getCookies(url: uri)) {
      await manager.deleteCookie(
        url: uri,
        name: cookie.name,
        domain: cookie.domain,
        path: cookie.path ?? '/',
      );
    }
    await WebStorageManager.instance().deleteOrigin(
      origin: SplatNetPolicy.origin,
    );
  }

  Future<void> closeResources() {
    lease?.release();
    session = null;
    document++;
    final id = operationId;
    operationId = null;
    if (id != null) unawaited(cancelAccountToolQuietly(tools, id));
    final closing = cleanup ??= resources.close(releaseNativeResources);
    _browserCleanup = closing;
    // The original failed future stays in the global gate and is shown by the
    // account action; this listener only prevents an unhandled async exception.
    unawaited(closing.catchError((Object _) {}));
    return closing;
  }

  Future<void> releaseNativeResources() async {
    await nativeView.close(() async {
      if (mounted) setState(() => nativeVisible = false);
      web = null;
      await WidgetsBinding.instance.endOfFrame;
    });
    if (Platform.isAndroid) await clearAndroidSite();
    if (Platform.isMacOS && macConfigured) {
      await SplatNetMacNetwork.clear();
      macConfigured = false;
    }
    final oldEnvironment = environment;
    environment = null;
    if (oldEnvironment != null) await oldEnvironment.dispose();
    final directory = profileDirectory;
    final parent = profileParent;
    final backend = widget.backend;
    profileDirectory = null;
    if (directory != null &&
        parent != null &&
        p.isWithin(parent, directory.absolute.path) &&
        !await FileSystemEntity.isLink(directory.path)) {
      await retireSplatNetProfile(
        deleteProfile: () => deleteOwnedSplatNetProfile(directory, parent),
        onIssue: (issue) {
          unawaited(
            backend
                .logError('[splatnet] profile cleanup', StateError(issue))
                .catchError((Object _) {}),
          );
        },
      );
    }
  }

  Future<void> deliverToken() => sessionRequests.run(() async {
    if (!valid || !ready) return;
    if (!Platform.isAndroid &&
        widget.backend.settings.proxyUrl != proxyAtCreation) {
      await fail(StateError('splatnet_proxy_changed'));
      return;
    }
    final generation = document;
    final controller = web;
    try {
      final before = await controller?.getUrl();
      if (before == null || !SplatNetPolicy.isOfficial(before.uriValue)) return;
      final value = await fetchSession();
      final after = await controller?.getUrl();
      if (!valid ||
          generation != document ||
          !identical(controller, web) ||
          after == null ||
          !SplatNetPolicy.isOfficial(after.uriValue)) {
        return;
      }
      await controller!.evaluateJavascript(
        source: SplatNetPolicy.deliverScript(value.gameWebToken),
      );
    } catch (failure) {
      if (valid && generation == document) await fail(failure);
    }
  });

  Future<void> installCloseWatcher(InAppWebViewController controller) async {
    await controller.evaluateJavascript(source: splatNetCloseWatcherScript);
  }

  Future<void> closeFromWebsite() async {
    if (!valid) return;
    final navigator = Navigator.of(context);
    leaving = true;
    lease?.release();
    setState(() => ready = false);
    await closeSplatNetAndReturn(
      closeResources: closeResources,
      onCleanupError: (failure) {
        unawaited(
          widget.backend
              .logError('[splatnet] WebView cleanup failed', failure)
              .catchError((Object _) {}),
        );
      },
      returnToCaller: () async {
        if (!mounted) return;
        setState(() => allowPop = true);
        await WidgetsBinding.instance.endOfFrame;
        if (mounted) navigator.pop();
      },
    );
  }

  Future<void> fail(Object failure) async {
    if (!mounted || leaving || error != null) return;
    lease?.release();
    setState(() {
      ready = false;
      error = failure;
    });
    unawaited(
      widget.backend
          .logError('[splatnet] WebView operation failed', failure)
          .catchError((Object _) {}),
    );
    try {
      await closeResources();
    } catch (_) {
      // Keep the failed cleanup future: a retry must not bypass isolation.
    }
  }

  Future<void> refresh() => sessionRequests.run(() async {
    if (!valid || !ready) return;
    setState(() {});
    try {
      session = await fetchSession(force: true);
      if (valid) await web?.reload();
    } catch (failure) {
      await fail(failure);
    } finally {
      if (mounted) setState(() {});
    }
  });

  Future<void> back() async {
    if (leaving) return;
    if (MediaQuery.viewInsetsOf(context).bottom > 0) {
      FocusManager.instance.primaryFocus?.unfocus();
      return;
    }
    if (ready && await web?.canGoBack() == true) {
      await web?.goBack();
      return;
    }
    leaving = true;
    lease?.release();
    setState(() {
      ready = false;
    });
    try {
      await closeResources();
    } catch (failure) {
      // openSplatNetPage also awaits the retained failure and displays it.
      if (mounted) setState(() => error = failure);
    } finally {
      if (mounted) {
        setState(() => allowPop = true);
        await WidgetsBinding.instance.endOfFrame;
        if (mounted) Navigator.of(context).pop();
      }
    }
  }

  @override
  void dispose() {
    lifecycleEvents?.removeListener(onPolicyChanged);
    lease?.release();
    _browserCleanup = closeResources();
    // Retain the failed future for the next entry; avoid an unhandled async error.
    unawaited(_browserCleanup.catchError((Object _) {}));
    unawaited(
      _browserCleanup
          .then((_) => credentialCleanup?.remove())
          .catchError((Object _) {}),
    );
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final nativeOwner = nativeView;
    bool currentValid() => identical(nativeOwner, nativeView) && valid;
    return PopScope<Object?>(
      canPop: allowPop,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) unawaited(back());
      },
      child: AccountToolFrame(
        mobile: widget.mobile,
        title: context.l10n.select(zh: '鱿鱼圈', en: 'SplatNet 3'),
        onBack: back,
        actions: [
          IconButton(
            tooltip: context.l10n.select(zh: '刷新', en: 'Refresh'),
            onPressed: ready && !sessionRequests.busy ? refresh : null,
            icon: const Icon(Icons.refresh),
          ),
        ],
        child: !nativeVisible || !nativeOwner.beginCreation()
            ? error != null
                  ? ListView(
                      padding: const EdgeInsets.all(16),
                      children: [
                        AccountToolError(error: error!, onRetry: prepare),
                        if (error.toString().contains('webview2'))
                          TextButton(
                            onPressed: () => launchUrl(
                              Uri.parse(
                                'https://developer.microsoft.com/microsoft-edge/webview2/',
                              ),
                              mode: LaunchMode.externalApplication,
                            ),
                            child: Text(
                              context.l10n.select(
                                zh: '打开 WebView2 官方下载页',
                                en: 'Open the official WebView2 download page',
                              ),
                            ),
                          ),
                      ],
                    )
                  : const Center(child: CircularProgressIndicator())
            : AbsorbPointer(
                absorbing: !valid || !ready,
                child: Column(
                  children: [
                    SizedBox(
                      height: 2,
                      child: progress < 100
                          ? LinearProgressIndicator(value: progress / 100)
                          : null,
                    ),
                    Expanded(
                      child: InAppWebView(
                        key: ObjectKey(nativeOwner),
                        keepAlive: nativeOwner.keepAlive,
                        webViewEnvironment: environment?.webViewEnvironment,
                        initialSettings: InAppWebViewSettings(
                          javaScriptEnabled: true,
                          useShouldOverrideUrlLoading: true,
                          javaScriptCanOpenWindowsAutomatically: false,
                          supportMultipleWindows: true,
                          allowFileAccess: false,
                          allowContentAccess: false,
                          allowFileAccessFromFileURLs: false,
                          allowUniversalAccessFromFileURLs: false,
                          thirdPartyCookiesEnabled: false,
                          sharedCookiesEnabled: false,
                          incognito: Platform.isWindows,
                          // macOS must use the default data store configured above.
                          cacheEnabled: Platform.isMacOS,
                          isInspectable: false,
                          disableDefaultErrorPage: true,
                        ),
                        initialUserScripts: UnmodifiableListView([
                          UserScript(
                            source: SplatNetPolicy.bootstrapScript,
                            injectionTime:
                                UserScriptInjectionTime.AT_DOCUMENT_START,
                            forMainFrameOnly: true,
                            allowedOriginRules: {SplatNetPolicy.origin},
                          ),
                          UserScript(
                            source: splatNetCloseWatcherScript,
                            injectionTime:
                                UserScriptInjectionTime.AT_DOCUMENT_START,
                            forMainFrameOnly: true,
                            allowedOriginRules: {SplatNetPolicy.origin},
                          ),
                        ]),
                        onWebViewCreated: (controller) {
                          final acceptsEvents = nativeOwner.created(
                            nativeViewId: controller.getViewId() as String?,
                          );
                          if (!acceptsEvents || !currentValid()) return;
                          web = controller;
                          controller.addJavaScriptHandler(
                            handlerName: 'nsoRequestGameWebToken',
                            callback: (_) {
                              if (currentValid()) unawaited(deliverToken());
                              return null;
                            },
                          );
                          controller.addJavaScriptHandler(
                            handlerName: 'splatnetClosed',
                            callback: (_) {
                              // Return to JS before disposing its native view.
                              if (currentValid()) unawaited(closeFromWebsite());
                              return null;
                            },
                          );
                          unawaited(() async {
                            try {
                              await controller.loadUrl(
                                urlRequest: URLRequest(
                                  url: WebUri.uri(entryUrl!),
                                ),
                              );
                            } catch (failure) {
                              if (currentValid()) await fail(failure);
                            }
                          }());
                        },
                        onLoadStart: (_, url) {
                          if (!currentValid()) return;
                          document++;
                        },
                        onLoadStop: (controller, url) async {
                          if (!currentValid() ||
                              url == null ||
                              !SplatNetPolicy.isOfficial(url.uriValue)) {
                            return;
                          }
                          try {
                            await controller.evaluateJavascript(
                              source: SplatNetPolicy.bootstrapScript,
                            );
                            await installCloseWatcher(controller);
                            if (currentValid()) await deliverToken();
                          } catch (failure) {
                            if (currentValid()) await fail(failure);
                          }
                        },
                        onProgressChanged: (_, value) {
                          if (currentValid()) setState(() => progress = value);
                        },
                        onCloseWindow: (_) {
                          if (currentValid()) unawaited(closeFromWebsite());
                        },
                        onConsoleMessage: (_, message) {
                          if (currentValid() &&
                              (message.messageLevel ==
                                      ConsoleMessageLevel.ERROR ||
                                  message.messageLevel ==
                                      ConsoleMessageLevel.WARNING)) {
                            // Never persist arbitrary JS output, which can contain credentials.
                            unawaited(
                              widget.backend
                                  .logError(
                                    '[splatnet] JavaScript console error',
                                    StateError('javascript_console_error'),
                                  )
                                  .catchError((Object _) {}),
                            );
                          }
                        },
                        shouldOverrideUrlLoading: (_, action) async {
                          if (!currentValid()) {
                            return NavigationActionPolicy.CANCEL;
                          }
                          final url = action.request.url;
                          if (url == null) return NavigationActionPolicy.CANCEL;
                          if (!action.isForMainFrame) {
                            return NavigationActionPolicy.ALLOW;
                          }
                          if (SplatNetPolicy.isOfficial(url.uriValue)) {
                            if (!Platform.isAndroid &&
                                widget.backend.settings.proxyUrl !=
                                    proxyAtCreation) {
                              unawaited(
                                fail(StateError('splatnet_proxy_changed')),
                              );
                              return NavigationActionPolicy.CANCEL;
                            }
                            return NavigationActionPolicy.ALLOW;
                          }
                          final external = SplatNetPolicy.externalUrl(
                            url.uriValue,
                          );
                          if (external != null && action.hasGesture == true) {
                            await launchUrl(
                              external,
                              mode: LaunchMode.externalApplication,
                            );
                          }
                          return NavigationActionPolicy.CANCEL;
                        },
                        onCreateWindow: (_, action) async {
                          if (!currentValid()) return false;
                          final url = action.request.url;
                          if (url != null && action.hasGesture == true) {
                            final external = SplatNetPolicy.externalUrl(
                              url.uriValue,
                            );
                            if (SplatNetPolicy.isOfficial(url.uriValue)) {
                              await web?.loadUrl(
                                urlRequest: URLRequest(url: url),
                              );
                            } else if (external != null) {
                              await launchUrl(
                                external,
                                mode: LaunchMode.externalApplication,
                              );
                            }
                          }
                          return false;
                        },
                        onPermissionRequest: (_, request) async =>
                            PermissionResponse(
                              resources: request.resources,
                              action: PermissionResponseAction.DENY,
                            ),
                        onReceivedServerTrustAuthRequest: (_, _) =>
                            splatNetServerTrustResponse(
                              platform: Platform.operatingSystem,
                            ),
                        onReceivedHttpAuthRequest: (_, _) async =>
                            HttpAuthResponse(
                              action: HttpAuthResponseAction.CANCEL,
                            ),
                        onReceivedError: (_, request, _) {
                          if (currentValid() &&
                              request.isForMainFrame == true) {
                            unawaited(
                              fail(StateError('splatnet_network_failed')),
                            );
                          }
                        },
                        onReceivedHttpError: (_, request, response) {
                          if (currentValid() &&
                              request.isForMainFrame == true) {
                            unawaited(
                              fail(
                                StateError(
                                  response.statusCode == 429
                                      ? 'rate_limited'
                                      : 'splatnet_network_failed',
                                ),
                              ),
                            );
                          }
                        },
                      ),
                    ),
                  ],
                ),
              ),
      ),
    );
  }
}
