import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import 'android_media_swipe_region.dart';

/// A decoder failure is local to this item, not a reason to trap the viewer.
class AndroidVideoFailureView extends StatelessWidget {
  const AndroidVideoFailureView({super.key, this.onSwipe});
  final ValueChanged<int>? onSwipe;

  @override
  Widget build(BuildContext context) => AndroidMediaSwipeRegion(
    onSwipe: (delta) => onSwipe?.call(delta),
    child: Center(
      child: Text(
        context.l10n.select(zh: '无法播放这个视频', en: 'Unable to play this video'),
        textAlign: TextAlign.center,
      ),
    ),
  );
}
