// lib/frontend/widgets/video_stage.dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import '../../backend/rtc_engine.dart';

class VideoStage extends StatelessWidget {
  const VideoStage({
    super.key,
    required this.engine,
    required this.roomId,
  });

  final WebRTCEngine engine;
  final String roomId;

  @override
  Widget build(BuildContext context) {
    final e = engine;
    final shareLink = 'webrtc://208.123.185.205/$roomId';

    return Stack(
      children: [
        // REMOTE — на весь экран, без клипов/скруглений/AspectRatio
        Positioned.fill(
          child: Stack(
            fit: StackFit.expand,
            children: [
              const ColoredBox(color: Colors.black), // фон
              RTCVideoView(
                e.remoteRenderer,
                objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
                placeholderBuilder: (_) =>
                    const Center(child: CircularProgressIndicator(strokeWidth: 2)),
              ),
            ],
          ),
        ),

        // ======= Верхняя строчка: Room + copy / Chat / статус =======
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                _RoomInfo(roomId: roomId, shareLink: shareLink),
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

        // ======= Self-view (с кнопкой Switch в углу) =======
        Positioned(
          right: 12,
          bottom: 110, // чтобы не перекрыть нижнюю панель
          child: _SelfViewMini(engine: e),
        ),

        // ======= Нижняя панель управления (тёмная, адаптивная) =======
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: SafeArea(
            top: false,
            child: _ControlsBar(engine: e),
          ),
        ),
      ],
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
                      icon:
                          const Icon(Icons.clear_all, color: Colors.white70),
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
            Text('Room: $roomId',
                style: const TextStyle(color: Colors.white)),
            const SizedBox(width: 8),
            InkWell(
              onTap: () => Clipboard.setData(ClipboardData(text: shareLink)),
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

class _SelfViewMini extends StatelessWidget {
  const _SelfViewMini({required this.engine});
  final WebRTCEngine engine;

  @override
  Widget build(BuildContext context) {
    const double h = 180.0;

    // После построения перебиндим превью (на iOS это стабилизирует показ).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      engine.forceRebindLocal();
    });

    return ValueListenableBuilder<bool>(
      valueListenable: engine.camOn,
      builder: (_, __, ___) {
        return Container(
          height: h,
          width: h * (9 / 16),
          decoration: BoxDecoration(
            color: Colors.black,
            // ВАЖНО: никаких скруглений/клипов вокруг RTCVideoView.
            // Можно оставить рамку/тень, но без clip.
            border: Border.all(color: Colors.white24),
            boxShadow: const [BoxShadow(blurRadius: 12, color: Colors.black54)],
          ),
          child: RTCVideoView(
            engine.localRenderer,
            mirror: true,
            objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
            placeholderBuilder: (_) => const ColoredBox(color: Colors.black54),
          ),
        );
      },
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
      color: Colors.black.withOpacity(.35), // тёмная прозрачная подложка
      child: Wrap(
        alignment: WrapAlignment.center,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 8,
        runSpacing: 8, // чтобы на телефоне аккуратно переносилось
        children: [
          ValueListenableBuilder<bool>(
            valueListenable: e.muted,
            builder: (_, m, __) => _darkPill(
              icon: m ? Icons.volume_up : Icons.volume_off,
              label: m ? 'Unmute' : 'Mute',
              onTap: e.toggleMute,
            ),
          ),
          ValueListenableBuilder<bool>(
            valueListenable: e.micOn,
            builder: (_, mic, __) => _darkPill(
              icon: mic ? Icons.mic_off : Icons.mic,
              label: mic ? 'Stop Mic' : 'Start Mic',
              onTap: mic ? e.stopMic : e.startMic,
            ),
          ),
          ValueListenableBuilder<bool>(
            valueListenable: e.camOn,
            builder: (_, cam, __) => _darkPill(
              icon: cam ? Icons.videocam_off : Icons.videocam,
              label: cam ? 'Stop Cam' : 'Start Cam',
              onTap: cam ? e.stopCam : e.startCam,
            ),
          ),
          // Спейсер не используем — Wrap сам расставит
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
      onPressed: () async {
        await e.hangUp(); // отправит 'bye', почистит peer и вернёт в лобби
      },

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
