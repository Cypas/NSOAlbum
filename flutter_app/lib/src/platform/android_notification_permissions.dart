import 'package:flutter/services.dart';
import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';

enum AndroidNotificationPermissionState {
  allowed,
  requestable,
  blocked,
  unavailable,
}

class AndroidNotificationPermissions {
  const AndroidNotificationPermissions();

  static const _channel = MethodChannel(
    'io.github.cypas.nsoalbum/notifications',
  );

  Future<AndroidNotificationPermissionState> status() async {
    final value = await _channel.invokeMethod<String>(
      'notificationPermissionStatus',
    );
    return switch (value) {
      'allowed' => AndroidNotificationPermissionState.allowed,
      'requestable' => AndroidNotificationPermissionState.requestable,
      'blocked' => AndroidNotificationPermissionState.blocked,
      _ => AndroidNotificationPermissionState.unavailable,
    };
  }

  Future<AndroidNotificationPermissionState> request() async {
    final value = await _channel.invokeMethod<String>('requestSyncPermission');
    return switch (value) {
      'allowed' => AndroidNotificationPermissionState.allowed,
      'requestable' => AndroidNotificationPermissionState.requestable,
      'blocked' => AndroidNotificationPermissionState.blocked,
      _ => AndroidNotificationPermissionState.unavailable,
    };
  }

  Future<void> openSettings() =>
      _channel.invokeMethod<void>('openNotificationSettings');
}

Future<bool> ensureAndroidNotificationPermission(BuildContext context) async {
  const permissions = AndroidNotificationPermissions();
  var state = await permissions.status();
  if (state == AndroidNotificationPermissionState.allowed) return true;
  if (!context.mounted) return false;

  if (state == AndroidNotificationPermissionState.requestable) {
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          context.l10n.select(zh: '允许同步通知？', en: 'Allow sync notifications?'),
        ),
        content: Text(
          context.l10n.select(
            zh: '自动同步新增媒体后，应用会通过系统通知展示同步结果。',
            en: 'The system will show the result when automatic sync adds media.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(context.l10n.select(zh: '暂不', en: 'Not now')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(
              context.l10n.select(zh: '允许通知', en: 'Allow notifications'),
            ),
          ),
        ],
      ),
    );
    if (accepted == true) state = await permissions.request();
  }

  if (state == AndroidNotificationPermissionState.allowed) return true;
  if (!context.mounted) return false;
  final openSettings = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(
        context.l10n.select(zh: '通知权限未开启', en: 'Notifications are disabled'),
      ),
      content: Text(
        context.l10n.select(
          zh: '请在系统设置中允许鱿型相册发送通知，才能展示自动同步结果。',
          en: 'Allow NSOAlbum notifications in system settings to show automatic sync results.',
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text(context.l10n.select(zh: '取消', en: 'Cancel')),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: Text(
            context.l10n.select(zh: '打开系统设置', en: 'Open system settings'),
          ),
        ),
      ],
    ),
  );
  if (openSettings == true) {
    await permissions.openSettings();
    if (!context.mounted) return false;
    // The page will re-check on resume; this immediate check keeps the switch
    // disabled until Android confirms the permission.
    return (await permissions.status()) ==
        AndroidNotificationPermissionState.allowed;
  }
  return false;
}
