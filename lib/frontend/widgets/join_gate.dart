// lib/frontend/widgets/join_gate.dart
import 'package:flutter/material.dart';
import '../../backend/rtc_engine.dart';

class JoinGate extends StatefulWidget {
  const JoinGate({
    super.key,
    required this.engine,
    required this.roomId,
    required this.onJoined,
  });

  final WebRTCEngine engine;
  final String roomId;
  final VoidCallback onJoined;

  @override
  State<JoinGate> createState() => _JoinGateState();
}

class _JoinGateState extends State<JoinGate> {
  bool _busy = false;

  Future<void> _doJoin({required bool cam}) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      // важно: инициализируем рендереры ДО joinRoom
      await widget.engine.init();

      await widget.engine.joinRoom(
        widget.roomId,
        withMic: true,
        withCam: cam,
      );

      widget.onJoined(); // переходим на CallPage
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Join failed: $e')),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final roomId = widget.roomId;

    return Scaffold(
      appBar: AppBar(title: const Text('Join Room')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  'You were invited to join room:\n$roomId',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 24),
                FilledButton.icon(
                  onPressed: _busy ? null : () => _doJoin(cam: true),
                  icon: const Icon(Icons.videocam),
                  label: _busy
                      ? const Text('Joining…')
                      : const Text('Join with camera & mic'),
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: _busy ? null : () => _doJoin(cam: false),
                  icon: const Icon(Icons.mic),
                  label: const Text('Join with mic only'),
                ),
                const SizedBox(height: 16),
                if (_busy) const CircularProgressIndicator(),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
