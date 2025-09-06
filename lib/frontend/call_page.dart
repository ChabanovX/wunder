// lib/frontend/call_page.dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../backend/rtc_engine.dart';

class CallPage extends StatefulWidget {
  const CallPage({super.key, required this.engine});
  final WebRTCEngine engine;

  @override
  State<CallPage> createState() => _CallPageState();
}

class _CallPageState extends State<CallPage> {
  final _roomCtrl = TextEditingController();
  final _chatCtrl = TextEditingController();

  bool _wantMic = true;
  bool _wantCam = true;

  @override
  void initState() {
    super.initState();
    widget.engine.init();
  }

  @override
  void dispose() {
    _roomCtrl.dispose();
    _chatCtrl.dispose();
    widget.engine.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final e = widget.engine;

    return Scaffold(
      appBar: AppBar(title: const Text('Wunder Calls'), centerTitle: true),
      body: ValueListenableBuilder<String?>(
        valueListenable: e.roomId,
        builder: (_, room, __) {
          if (room == null || room.isEmpty) {
            return _buildLobby(e);
          }
          return _buildInCall(e, room);
        },
      ),
    );
  }

  // -------------------------- LOBBY --------------------------

  Widget _buildLobby(WebRTCEngine e) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: Card(
          elevation: 2,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Create or Join a Room',
                    style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600)),
                const SizedBox(height: 16),
                TextField(
                  controller: _roomCtrl,
                  decoration: InputDecoration(
                    labelText: 'Room ID or link',
                    hintText: 'вставь id или ссылку',
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                    prefixIcon: const Icon(Icons.meeting_room_outlined),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    FilterChip(
                      label: const Text('Mic'),
                      selected: _wantMic,
                      onSelected: (v) => setState(() => _wantMic = v),
                    ),
                    const SizedBox(width: 8),
                    FilterChip(
                      label: const Text('Camera'),
                      selected: _wantCam,
                      onSelected: (v) => setState(() => _wantCam = v),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  alignment: WrapAlignment.center,
                  children: [
                    FilledButton.icon(
                      onPressed: () => e.createRoom(withMic: _wantMic, withCam: _wantCam),
                      icon: const Icon(Icons.add_circle_outline),
                      label: const Text('Create room'),
                    ),
                    OutlinedButton.icon(
                      onPressed: () => e.joinRoom(_roomCtrl.text, withMic: _wantMic, withCam: _wantCam),
                      icon: const Icon(Icons.login),
                      label: const Text('Join room'),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                const Divider(height: 28),
                Text(
                  'Совет: включи Mic/Camera перед созданием/входом,\nчтобы они сразу попали в первый SDP-раунд.',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ------------------------- IN CALL -------------------------

  Widget _buildInCall(WebRTCEngine e, String room) {
    final shareLink = 'webrtc://208.123.185.205/$room';
    final screenH = MediaQuery.of(context).size.height;
    final videoH = (screenH * 0.55).clamp(280.0, 720.0); // явная высота

    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: Card(
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SelectableText('Room ID: $room'),
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            Expanded(child: SelectableText('Link: $shareLink')),
                            IconButton(
                              tooltip: 'Copy link',
                              icon: const Icon(Icons.copy_all_rounded),
                              onPressed: () => Clipboard.setData(ClipboardData(text: shareLink)),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              ValueListenableBuilder<bool>(
                valueListenable: e.connected,
                builder: (_, ok, __) => Chip(
                  avatar: Icon(ok ? Icons.check_circle : Icons.sync, size: 18),
                  label: Text(ok ? 'Connected' : 'Connecting…'),
                ),
              ),
            ],
          ),

          const SizedBox(height: 8),

          // ===== СТАБИЛЬНЫЙ ПОРТРЕТНЫЙ ВИДЕО-БЛОК (9:16), БЕЗ КЛИПОВ =====
          SizedBox(
            height: videoH.toDouble(),
            width: double.infinity,
            child: Container(
              color: Colors.black,
              child: Stack(
                children: [
                  // REMOTE — портрет 9:16, вписан (Contain) => без обрезки
                  Center(
                    child: AspectRatio(
                      aspectRatio: 9 / 16,
                      child: RTCVideoView(
                        e.remoteRenderer,
                        // Для надёжного старта — Contain. Можно сменить на Cover.
                        objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
                        placeholderBuilder: (_) =>
                            const Center(child: CircularProgressIndicator(strokeWidth: 2)),
                      ),
                    ),
                  ),
                  // SELF — тоже 9:16, маленькое окно, без клипов
                  Positioned(
                    right: 12,
                    bottom: 12,
                    child: _miniPortraitSelf(e, maxHeight: videoH * 0.35),
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 10),

          _buildControls(e),

          const SizedBox(height: 10),

          Expanded(
            child: Row(
              children: [
                Expanded(
                  flex: 2,
                  child: Card(
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    child: Padding(
                      padding: const EdgeInsets.all(10),
                      child: Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _chatCtrl,
                              decoration: const InputDecoration(
                                hintText: 'Type message…',
                                border: OutlineInputBorder(),
                                isDense: true,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          FilledButton(
                            onPressed: () {
                              e.sendChat(_chatCtrl.text);
                              _chatCtrl.clear();
                            },
                            child: const Text('Send'),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  flex: 3,
                  child: Card(
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    child: Padding(
                      padding: const EdgeInsets.all(10),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Row(
                            children: [
                              const Text('Logs', style: TextStyle(fontWeight: FontWeight.bold)),
                              const Spacer(),
                              IconButton(
                                tooltip: 'Copy',
                                onPressed: () async {
                                  final text = widget.engine.logs.value.join('\n');
                                  await Clipboard.setData(ClipboardData(text: text));
                                  if (!mounted) return;
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(content: Text('Logs copied')),
                                  );
                                },
                                icon: const Icon(Icons.copy),
                              ),
                              IconButton(
                                tooltip: 'Clear',
                                onPressed: () => widget.engine.logs.value = [],
                                icon: const Icon(Icons.clear_all),
                              ),
                              IconButton(
                                tooltip: 'Dump ICE',
                                onPressed: widget.engine.dumpSelectedIce,
                                icon: const Icon(Icons.downloading),
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          Expanded(
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                border: Border.all(color: Colors.black12),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Padding(
                                padding: const EdgeInsets.all(8),
                                child: ValueListenableBuilder<List<String>>(
                                  valueListenable: widget.engine.logs,
                                  builder: (_, list, __) => SingleChildScrollView(
                                    child: SelectableText(list.join('\n')),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Мини-окно для локальной камеры (портрет 9:16), без клипов.
  /// Размер задаём явный по высоте — это важно для стабильного старта.
  Widget _miniPortraitSelf(WebRTCEngine e, {double maxHeight = 260}) {
    final h = maxHeight.clamp(140.0, 360.0);
    return Container(
      height: h,
      width: h * (9 / 16), // портретное соотношение
      decoration: BoxDecoration(
        color: Colors.black,
        border: Border.all(color: Colors.white24, width: 1),
        borderRadius: BorderRadius.circular(10),
        boxShadow: const [BoxShadow(blurRadius: 12, color: Colors.black54)],
      ),
      child: RTCVideoView(
        e.localRenderer,
        mirror: true,
        objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
        placeholderBuilder: (_) => const ColoredBox(color: Colors.black54),
      ),
    );
  }

  Widget _buildControls(WebRTCEngine e) {
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: ValueListenableBuilder2<bool, bool>(
          first: e.micOn,
          second: e.camOn,
          builder: (_, mic, cam, __) {
            return Wrap(
              spacing: 8,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              children: [
                FilledButton.tonalIcon(
                  onPressed: mic ? e.stopMic : e.startMic,
                  icon: Icon(mic ? Icons.mic_off : Icons.mic),
                  label: Text(mic ? 'Stop Mic' : 'Start Mic'),
                ),
                ValueListenableBuilder<bool>(
                  valueListenable: e.muted,
                  builder: (_, m, __) => FilledButton.tonalIcon(
                    onPressed: e.toggleMute,
                    icon: Icon(m ? Icons.volume_up : Icons.volume_off),
                    label: Text(m ? 'Unmute' : 'Mute'),
                  ),
                ),
                FilledButton.tonalIcon(
                  onPressed: cam ? e.stopCam : e.startCam,
                  icon: Icon(cam ? Icons.videocam_off : Icons.videocam),
                  label: Text(cam ? 'Stop Cam' : 'Start Cam'),
                ),
                OutlinedButton.icon(
                  onPressed: e.switchCamera,
                  icon: const Icon(Icons.cameraswitch),
                  label: const Text('Switch'),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// Для двух ValueNotifier одновременно
class ValueListenableBuilder2<A, B> extends StatelessWidget {
  const ValueListenableBuilder2({
    super.key,
    required this.first,
    required this.second,
    required this.builder,
  });

  final ValueListenable<A> first;
  final ValueListenable<B> second;
  final Widget Function(BuildContext, A, B, Widget?) builder;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<A>(
      valueListenable: first,
      builder: (context, a, _) {
        return ValueListenableBuilder<B>(
          valueListenable: second,
          builder: (context, b, child) => builder(context, a, b, child),
        );
      },
    );
  }
}
