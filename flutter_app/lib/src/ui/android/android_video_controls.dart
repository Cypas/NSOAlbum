import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';

String _time(Duration value) {
  final seconds = value.inSeconds;
  final mm = (seconds ~/ 60).toString().padLeft(2, '0');
  final ss = (seconds % 60).toString().padLeft(2, '0');
  return '$mm:$ss';
}

/// Kept outside the swipe region: scrubbing never changes the selected media.
class AndroidVideoControls extends StatelessWidget {
  const AndroidVideoControls({
    super.key,
    required this.playing,
    required this.position,
    required this.duration,
    required this.muted,
    required this.onToggle,
    required this.onMute,
    required this.onSeek,
    this.enabled = true,
  });
  final bool playing, muted, enabled;
  final Duration position, duration;
  final VoidCallback onToggle, onMute;
  final ValueChanged<Duration> onSeek;

  @override
  Widget build(BuildContext context) => Material(
    color: Theme.of(context).colorScheme.surface,
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            IconButton(
              key: const Key('android-video-toggle'),
              tooltip: playing
                  ? context.l10n.select(zh: '暂停', en: 'Pause')
                  : context.l10n.select(zh: '播放', en: 'Play'),
              onPressed: enabled ? onToggle : null,
              icon: Icon(playing ? Icons.pause : Icons.play_arrow),
            ),
            Expanded(
              child: Text(
                '${_time(position)} / ${_time(duration)}',
                key: const Key('android-video-position'),
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
            IconButton(
              tooltip: muted
                  ? context.l10n.select(zh: '取消静音', en: 'Unmute')
                  : context.l10n.select(zh: '静音', en: 'Mute'),
              onPressed: enabled ? onMute : null,
              icon: Icon(muted ? Icons.volume_off : Icons.volume_up),
            ),
          ],
        ),
        Semantics(
          label: context.l10n.select(zh: '视频进度', en: 'Video position'),
          child: Slider(
            key: const Key('android-video-seek'),
            value: position.inMilliseconds.toDouble().clamp(
              0,
              duration.inMilliseconds.clamp(1, 1 << 53).toDouble(),
            ),
            max: duration.inMilliseconds.clamp(1, 1 << 53).toDouble(),
            onChanged: !enabled || duration <= Duration.zero
                ? null
                : (value) => onSeek(Duration(milliseconds: value.round())),
          ),
        ),
      ],
    ),
  );
}
