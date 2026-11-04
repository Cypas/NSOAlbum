import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../android/android_page_frame.dart';
import '../app_image_viewer.dart';

Future<void> showNintendoAvatarPreview(
  BuildContext context, {
  required Uint8List bytes,
  required String nickname,
}) async {
  if (bytes.isEmpty) return;
  final png =
      bytes.length >= 4 &&
      bytes[0] == 0x89 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x4e &&
      bytes[3] == 0x47;
  final title = context.l10n.select(zh: '保存头像', en: 'Save avatar');
  await showAppImageViewer(
    context,
    items: [AppImageViewerItem(image: MemoryImage(bytes), label: nickname)],
    onSave: (_) async {
      try {
        await FilePicker.saveFile(
          fileName: 'nintendo_avatar.${png ? 'png' : 'jpg'}',
          bytes: bytes,
          mimeType: png ? 'image/png' : 'image/jpeg',
          dialogTitle: title,
        );
      } catch (error) {
        if (context.mounted) androidMessage(context, error);
      }
    },
  );
}
