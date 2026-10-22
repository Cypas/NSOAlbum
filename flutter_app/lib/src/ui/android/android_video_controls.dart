import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';

String _time(Duration value) {
  final seconds = value.inSeconds;
  final mm = (seconds ~/ 60).toString().padLeft(2, '0');
  final ss = (seconds % 60).toString().padLeft(2, '0');
  return '$mm:$ss';
}

/// Bottom video overlay, kept outside the sibling swipe listener's hit path.
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
  Widget build(BuildContext context) {
    final slider = SliderTheme.of(context);
    // Keep the preparation-to-ready paint stable. onChanged remains null until
    // seeking is available, so touch and accessibility readiness do not change.
    final stableSlider = slider.copyWith(
      activeTrackColor: Colors.white,
      disabledActiveTrackColor: Colors.white,
      inactiveTrackColor: const Color(0xff8f8f8f),
      disabledInactiveTrackColor: const Color(0xff8f8f8f),
      thumbColor: Colors.white,
      disabledThumbColor: Colors.white,
    );
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0x00000000), Color(0xb3000000)],
        ),
      ),
      child: Material(
        type: MaterialType.transparency,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                IconButton(
                  key: const Key('android-video-toggle'),
                  color: Colors.white,
                  disabledColor: Colors.white70,
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
                    style: Theme.of(context).textTheme.bodySmall
                        ?.copyWith(color: Colors.white),
                  ),
                ),
                IconButton(
                  color: Colors.white,
                  disabledColor: Colors.white70,
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
              child: SliderTheme(
                data: stableSlider,
                child: Slider(
                  key: const Key('android-video-seek'),
                  value: position.inMilliseconds.toDouble().clamp(
                    0,
                    duration.inMilliseconds.clamp(1, 1 << 53).toDouble(),
                  ),
                  max: duration.inMilliseconds.clamp(1, 1 << 53).toDouble(),
                  onChanged: !enabled || duration <= Duration.zero
                      ? null
                      : (value) =>
                            onSeek(Duration(milliseconds: value.round())),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
