import 'package:flutter/material.dart';

import '../../backend/sync_failure_status.dart';
import '../../l10n/app_localizations.dart';
import '../../rust/models.dart';
import '../../rust/settings.dart';
import 'android_page_frame.dart';

/// One status resolution for both the account overview and account settings.
({String text, Color color}) androidAccountStatus(
  BuildContext context, {
  required bool current,
  required bool cancelling,
  required bool authPaused,
  Object? error,
  SyncSummary? result,
  SyncRuntimeState? history,
}) {
  ({String text, Color color}) status(String zh, String en, Color color) =>
      (text: context.l10n.select(zh: zh, en: en), color: color);
  final active = Colors.blue.shade600;
  final success = Colors.green.shade600;
  final warning = Colors.amber.shade700;
  final failure = Colors.red.shade600;
  final neutral = Colors.grey.shade600;
  if (current) {
    return cancelling
        ? status('正在取消同步', 'Cancelling sync', active)
        : status('正在同步', 'Syncing', active);
  }
  if (authPaused) {
    return status(
      '登录已失效，等待重新登录',
      'Sign-in expired; waiting for sign-in',
      failure,
    );
  }
  if (error != null) {
    switch (syncFailureStatus(error)) {
      case 'rate_limited':
        return status('请求过于频繁，等待重试', 'Rate limited; waiting to retry', warning);
      case 'authentication_failure':
        return status(
          '登录已失效，等待重新登录',
          'Sign-in expired; waiting for sign-in',
          failure,
        );
      case 'cancelled':
        return status('同步已取消', 'Sync cancelled', neutral);
      default:
        return (text: androidReadableError(context, error), color: failure);
    }
  }
  if (result != null) {
    return result.failed > BigInt.zero
        ? status(
            '同步完成但有部分项目失败',
            'Sync completed with some failed items',
            warning,
          )
        : status('同步完成', 'Sync complete', success);
  }
  switch (history?.latestAttempt?.status) {
    case 'success':
    case 'completed':
      return status('上次同步成功', 'Last sync succeeded', success);
    case 'rate_limited':
      return status('请求过于频繁，等待重试', 'Rate limited; waiting to retry', warning);
    case 'cancelled':
      return status('上次同步已取消', 'Last sync was cancelled', neutral);
    case 'failure':
      return status('上次同步未完成', 'Last sync did not complete', failure);
    case 'partial_failure':
      return status('上次同步有部分项目失败', 'Last sync had some failed items', warning);
    case 'authentication_failure':
      return status(
        '登录已失效，等待重新登录',
        'Sign-in expired; waiting for sign-in',
        failure,
      );
  }
  return status('等待同步', 'Waiting to sync', neutral);
}
