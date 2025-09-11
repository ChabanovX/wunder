// lib/frontend/widgets/video_stage.dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import '../../backend/rtc_engine.dart';
import '../utils/deeplink.dart';

class VideoStage extends StatefulWidget {
  const VideoStage({
    super.key,
    required this.engine,
    required this.roomId,
  });

  final WebRTCEngine engine;
  final String roomId;

  @override
  State<VideoStage> createState() => _VideoStageState();
}

class _VideoStageState extends State<VideoStage> {
  // Позиция мини-окна (левый-верхний угол) в координатах Stack
  Offset? _selfPos;

  // Габариты мини-окна (портрет 9:16)
  static const double _selfH = 180.0;
  static const double _selfW = _selfH * (9 / 16);

  // Отступы и примерные высоты верхней/нижней панелей для расчёта границ
  static const double _pad = 12.0;
  static const double _topBarHeight = 44.0;     // высота строки Room/Copy/Status
  static const double _bottomBarHeight = 70.0;  // высота панели кнопок

  @override
  Widget build(BuildContext context) {
    final e = widget.engine;
    final shareLink = buildJoinUrl(widget.roomId);

    final safe = MediaQuery.of(context).padding;

    return LayoutBuilder(
      builder: (context, box) {
        // Рассчитываем границы перемещения превью
        final minX = _pad;
        final maxX = (box.maxWidth - _selfW - _pad).clamp(_pad, box.maxWidth);
        final minY = safe.top + _pad + _topBarHeight; // под верхней строкой
        final maxY = (box.maxHeight - _selfH - (safe.bottom + _pad + _bottomBarHeight))
            .clamp(0.0, box.maxHeight);

        // Стартовая позиция — справа снизу (как просили)
        _selfPos ??= Offset(maxX, maxY);

        // Клэмпим, если размеры экрана поменялись (поворот и т.п.)
        _selfPos = Offset(
          _selfPos!.dx.clamp(minX, maxX),
          _selfPos!.dy.clamp(minY, maxY),
        );

        return Stack(
          children: [
            // REMOTE — на весь экран
            Positioned.fill(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  const ColoredBox(color: Colors.black),
                  ValueListenableBuilder<bool>(
                    valueListenable: e.connected,
                    builder: (_, __, ___) => RTCVideoView(
                      e.remoteRenderer,
                      key: ValueKey(e.remoteRenderer.hashCode),
                      objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
                      placeholderBuilder: (_) =>
                          const Center(child: CircularProgressIndicator(strokeWidth: 2)),
                    ),
                  ),
                ],
              ),
            ),

            // Верх: Room + Copy / Chat / статус
            SafeArea(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Row(
                  children: [
                    _RoomInfo(roomId: widget.roomId, shareLink: shareLink),
                    const Spacer(),
                    _RoundIconButton(
                      icon: Icons.chat_bubble_outline_rounded,
                      onTap: () => _openLogsSheet(context, e),
                    ),
                    const SizedBox(width: 10),
                    ValueListenableBuilder<bool>(
                      valueListenable: e.connected,
                      builder: (_, ok, __) => Chip(
                        avatar: Icon(ok ? Icons.check_circle : Icons.sync, size: 18),
                        label: Text(ok ? 'Connected' : 'Connecting…'),
                      ),
                    ),
                  ],
                ),
              ),
            ),

            // Перетаскиваемое self-view
            Positioned(
              left: _selfPos!.dx,
              top: _selfPos!.dy,
              child: _DraggableSelfView(
                engine: e,
                width: _selfW,
                height: _selfH,
                onDragUpdate: (delta) {
                  setState(() {
                    final nx = (_selfPos!.dx + delta.dx).clamp(minX, maxX);
                    final ny = (_selfPos!.dy + delta.dy).clamp(minY, maxY);
                    _selfPos = Offset(nx, ny);
                  });
                },
              ),
            ),

            // Низ: панель управления
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: SafeArea(top: false, child: _ControlsBar(engine: e)),
            ),
          ],
        );
      },
    );
  }

  void _openLogsSheet(BuildContext context, WebRTCEngine e) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.black.withOpacity(.9),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) {
        return DraggableScrollableSheet(
          initialChildSize: 0.6,
          minChildSize: 0.3,
          maxChildSize: 0.95,
          expand: false,
          builder: (_, controller) => Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              children: [
                Row(
                  children: [
                    const Text('Chat & Logs',
                        style: TextStyle(
                            fontWeight: FontWeight.bold, color: Colors.white)),
                    const Spacer(),
                    IconButton(
                      tooltip: 'Copy logs',
                      icon: const Icon(Icons.copy_all, color: Colors.white70),
                      onPressed: () async {
                        final txt = e.logs.value.join('\n');
                        await Clipboard.setData(ClipboardData(text: txt));
                        if (Navigator.of(context).mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(content: Text('Logs copied')),
                          );
                        }
                      },
                    ),
                    IconButton(
                      tooltip: 'Clear',
                      icon: const Icon(Icons.clear_all, color: Colors.white70),
                      onPressed: () => e.logs.value = [],
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: ValueListenableBuilder<List<String>>(
                    valueListenable: e.logs,
                    builder: (_, list, __) => ListView.builder(
                      controller: controller,
                      itemCount: list.length,
                      itemBuilder: (_, i) =>
                          Text(list[i], style: const TextStyle(color: Colors.white70)),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

// ───────────────── helper widgets ─────────────────

class _RoomInfo extends StatelessWidget {
  const _RoomInfo({required this.roomId, required this.shareLink});
  final String roomId;
  final String shareLink;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(.35),
        borderRadius: BorderRadius.circular(24),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Room: $roomId', style: const TextStyle(color: Colors.white)),
            const SizedBox(width: 8),
            InkWell(
              onTap: () async {
                await Clipboard.setData(ClipboardData(text: shareLink));
                // лаконичный фидбек
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Copied')),
                );
              },
              borderRadius: BorderRadius.circular(16),
              child: const Padding(
                padding: EdgeInsets.all(4),
                child: Icon(Icons.copy_rounded, size: 18, color: Colors.white70),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DraggableSelfView extends StatelessWidget {
  const _DraggableSelfView({
    required this.engine,
    required this.width,
    required this.height,
    required this.onDragUpdate,
  });

  final WebRTCEngine engine;
  final double width;
  final double height;
  final ValueChanged<Offset> onDragUpdate;

  @override
  Widget build(BuildContext context) {
    // подстраховка от «чёрного экрана» на части девайсов
    WidgetsBinding.instance.addPostFrameCallback((_) => engine.forceRebindLocal());

    final r = BorderRadius.circular(16);

    return GestureDetector(
      onPanUpdate: (d) => onDragUpdate(d.delta),
      child: SizedBox(
        width: width,
        height: height,
        child: Stack(
          children: [
            ClipRRect(
              borderRadius: r,
              child: Container(
                color: Colors.black,
                child: ValueListenableBuilder<bool>(
                  valueListenable: engine.camOn,
                  builder: (_, __, ___) => RTCVideoView(
                    engine.localRenderer,
                    key: ValueKey(engine.camOn.value),
                    mirror: true,
                    objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                    placeholderBuilder: (_) => const ColoredBox(color: Colors.black54),
                  ),
                ),
              ),
            ),
            // рамка
            Positioned.fill(
              child: IgnorePointer(
                child: Container(
                  decoration: BoxDecoration(
                    borderRadius: r,
                    border: Border.all(color: Colors.white24, width: 1),
                  ),
                ),
              ),
            ),
            // кнопка смены камеры
            Positioned(
              right: 6,
              top: 6,
              child: Material(
                color: Colors.black.withOpacity(.45),
                shape: const CircleBorder(),
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: engine.switchCamera,
                  child: const Padding(
                    padding: EdgeInsets.all(8),
                    child: Icon(Icons.cameraswitch, size: 20, color: Colors.white),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ControlsBar extends StatelessWidget {
  const _ControlsBar({required this.engine});
  final WebRTCEngine engine;

  @override
  Widget build(BuildContext context) {
    final e = engine;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
      color: Colors.black.withOpacity(.35),
      child: Wrap(
        alignment: WrapAlignment.center,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 8,
        runSpacing: 8,
        children: [
          ValueListenableBuilder<bool>(
            valueListenable: e.muted,
            builder: (_, m, __) => _darkPill(
              icon: m ? Icons.volume_up : Icons.volume_off,
              label: m ? 'Unmute' : 'Mute',
              onTap: () => e.toggleMute(),
            ),
          ),
          ValueListenableBuilder<bool>(
            valueListenable: e.micOn,
            builder: (_, mic, __) => _darkPill(
              icon: mic ? Icons.mic_off : Icons.mic,
              label: mic ? 'Stop Mic' : 'Start Mic',
              onTap: () => mic ? e.stopMic() : e.startMic(),
            ),
          ),
          ValueListenableBuilder<bool>(
            valueListenable: e.camOn,
            builder: (_, cam, __) => _darkPill(
              icon: cam ? Icons.videocam_off : Icons.videocam,
              label: cam ? 'Stop Cam' : 'Start Cam',
              onTap: () => cam ? e.stopCam() : e.startCam(),
            ),
          ),
          _endButton(context, e),
        ],
      ),
    );
  }

  Widget _darkPill({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return FilledButton(
      onPressed: onTap,
      style: FilledButton.styleFrom(
        backgroundColor: Colors.white.withOpacity(.10),
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(28)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 18),
          const SizedBox(width: 8),
          Text(label),
        ],
      ),
    );
  }

  Widget _endButton(BuildContext context, WebRTCEngine e) {
    return FilledButton(
      style: FilledButton.styleFrom(
        backgroundColor: Colors.redAccent,
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      ),
      onPressed: () async => e.hangUp(),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [Icon(Icons.call_end), SizedBox(width: 6), Text('End')],
      ),
    );
  }
}

class _RoundIconButton extends StatelessWidget {
  const _RoundIconButton({required this.icon, required this.onTap});
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black.withOpacity(.35),
      shape: const CircleBorder(),
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Icon(icon, color: Colors.white),
        ),
      ),
    );
  }
}
