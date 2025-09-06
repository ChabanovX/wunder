// lib/frontend/widgets/self_view_portrait.dart
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import '../../backend/rtc_engine.dart';

class SelfViewPortrait extends StatelessWidget {
  const SelfViewPortrait(this.engine, {super.key, this.maxHeight = 220});
  final WebRTCEngine engine;
  final double maxHeight;

  @override
  Widget build(BuildContext context) {
    final h = maxHeight.clamp(140.0, 360.0);
    // подстраховка: после построения перебиндим превью на всякий случай
    WidgetsBinding.instance.addPostFrameCallback((_) {
      engine.forceRebindLocal();
    });

    return Container(
      height: h,
      width: h * (9 / 16),                 // фиксированное портретное соотношение
      decoration: BoxDecoration(
        color: Colors.black,
        border: Border.all(color: Colors.white24, width: 1),
        borderRadius: BorderRadius.circular(14),
        boxShadow: const [BoxShadow(blurRadius: 12, color: Colors.black54)],
      ),
      // ВАЖНО: НЕ клипать RTCVideoView (без Clip/clipBehavior), это часто даёт чёрный экран.
      child: Center(
        child: AspectRatio(
          aspectRatio: 9 / 16,
          child: RTCVideoView(
            engine.localRenderer,
            key: ValueKey(engine.camOn.value), // пересоздастся при on/off камеры
            mirror: true,
            objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
            placeholderBuilder: (_) => const ColoredBox(color: Colors.black54),
          ),
        ),
      ),
    );
  }
}
