import 'splatnet_policy.dart';

Future<void> closeSplatNetAndReturn({
  required Future<void> Function() closeResources,
  required void Function(Object error) onCleanupError,
  required Future<void> Function() returnToCaller,
}) async {
  try {
    await closeResources();
  } catch (error) {
    onCleanupError(error);
  }
  await returnToCaller();
}

const splatNetCloseWatcherScript =
    '''
(() => {
  if (window !== window.top ||
      window.location.origin !== '${SplatNetPolicy.origin}') return;
  if (window.__nsoAlbumCloseWatcher) return;
  window.__nsoAlbumCloseWatcher = true;
  let requested = false;
  const close = () => {
    if (window !== window.top ||
        window.location.origin !== '${SplatNetPolicy.origin}') return false;
    if (requested) return true;
    const channel = window.flutter_inappwebview;
    if (!channel || typeof channel.callHandler !== 'function') return false;
    requested = true;
    Promise.resolve(channel.callHandler('splatnetClosed')).catch(() => {
      requested = false;
    });
    return true;
  };
  // Coral web services use the native API, independently of visible labels.
  window.closeWebView = close;
  window.jsBridge = window.jsBridge || {};
  window.jsBridge.closeWebView = close;
  if (window.vh) window.vh.closeWebView = close;
  document.addEventListener('click', (event) => {
    const target = event.target instanceof Element
      ? event.target.closest('button,a,[role="button"]')
      : null;
    if (!target) return;
    const values = [
      target.innerText,
      target.getAttribute('aria-label'),
      target.getAttribute('title'),
      target.getAttribute('data-action'),
      target.getAttribute('data-testid'),
      target.getAttribute('data-cy'),
    ].filter(Boolean).map((value) => value.trim().toLowerCase());
    const labels = new Set([
      '关闭鱿鱼圈', '关闭鱿鱼圈3', '关闭鱿鱼圈 3',
      '關閉魷魚圈', '關閉魷魚圈3', '關閉魷魚圈 3',
      'イカリング3を閉じる', 'close splatnet', 'close splatnet 3',
      'close-splatnet', 'close_splatnet',
    ]);
    if (!values.some((value) => labels.has(value)) || !close()) return;
    event.preventDefault();
    event.stopImmediatePropagation();
  }, true);
})();
''';
