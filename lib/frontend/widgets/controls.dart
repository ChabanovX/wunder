import 'package:flutter/material.dart';
import '../../backend/rtc_engine.dart';
import '../utils/value_listenable2.dart';

class MediaControls extends StatelessWidget {
  const MediaControls({super.key, required this.engine});
  final WebRTCEngine engine;

  @override
  Widget build(BuildContext context) {
    final e = engine;
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
                  onPressed: () => mic ? e.stopMic() : e.startMic(),
                  icon: Icon(mic ? Icons.mic_off : Icons.mic),
                  label: Text(mic ? 'Stop Mic' : 'Start Mic'),
                ),
                ValueListenableBuilder<bool>(
                  valueListenable: e.muted,
                  builder: (_, m, __) => FilledButton.tonalIcon(
                    onPressed: () => e.toggleMute(),
                    icon: Icon(m ? Icons.volume_up : Icons.volume_off),
                    label: Text(m ? 'Unmute' : 'Mute'),
                  ),
                ),
                FilledButton.tonalIcon(
                  onPressed: () => cam ? e.stopCam() : e.startCam(),
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
