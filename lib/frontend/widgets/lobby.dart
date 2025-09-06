import 'package:flutter/material.dart';
import '../../backend/rtc_engine.dart';

class Lobby extends StatefulWidget {
  const Lobby({
    super.key,
    required this.engine,
    required this.roomCtrl,
  });

  final WebRTCEngine engine;
  final TextEditingController roomCtrl;

  @override
  State<Lobby> createState() => _LobbyState();
}

class _LobbyState extends State<Lobby> {
  bool _wantMic = true;
  bool _wantCam = true;

  @override
  Widget build(BuildContext context) {
    final e = widget.engine;

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
                  controller: widget.roomCtrl,
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
                      onPressed: () => e.joinRoom(widget.roomCtrl.text, withMic: _wantMic, withCam: _wantCam),
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
}
