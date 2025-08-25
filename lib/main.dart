import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MaterialApp(home: WebRTCDemo()));
}

class WebRTCDemo extends StatefulWidget {
  const WebRTCDemo({super.key});
  @override
  State<WebRTCDemo> createState() => _WebRTCDemoState();
}

class _WebRTCDemoState extends State<WebRTCDemo> {
  RTCPeerConnection? _pc;
  RTCDataChannel? _dc;
  MediaStream? _localStream;
  final _localSdpCtrl = TextEditingController();
  final _remoteSdpCtrl = TextEditingController();
  final _chatCtrl = TextEditingController();
  final _log = <String>[];

  void _logLine(String s) => setState(() => _log.add(s));

  Future<void> _createPeer({bool withMic = false}) async {
    // ICE servers: for LAN you can try empty; for internet use at least STUN.
    final config = {
      'iceServers': [
        // Try without servers on same Wi-Fi first; otherwise uncomment:
        // {'urls': 'stun:stun.l.google.com:19302'},
        // If you have TURN:
        // {'urls': ['turn:your.turn.server:3478'], 'username': 'u', 'credential': 'p'},
      ],
      'sdpSemantics': 'unified-plan',
    };
    final constraints = {
      'mandatory': {},
      'optional': [
        {'DtlsSrtpKeyAgreement': true},
      ],
    };

    final pc = await createPeerConnection(config, constraints);
    _pc = pc;

    // Optional: get microphone (or camera) and add tracks
    if (withMic) {
      _localStream = await navigator.mediaDevices.getUserMedia({
        'audio': true,
        'video': false,
      });
      for (var t in _localStream!.getTracks()) {
        await pc.addTrack(t, _localStream!);
      }
      _logLine('Mic stream added.');
    }

    // Data channel (created by the "offerer" side)
    pc.onDataChannel = (RTCDataChannel dc) {
      _dc = dc;
      _wireDataChannel();
      _logLine('DataChannel received: ${dc.label}');
    };

    // ICE candidates: we include them inside the SDP by waiting a bit,
    // but also set up trickle handling so late candidates still work.
    pc.onIceCandidate = (RTCIceCandidate cand) {
      // With proper signaling you’d send this cand to the remote.
      // For this manual demo, we rely on ICE candidates bundled in SDP.
      _logLine('ICE candidate: ${cand.candidate?.substring(0, 30)}…');
    };

    pc.onConnectionState = (state) {
      _logLine('PC state: $state');
    };
  }

  Future<void> _makeOffer() async {
    await _createPeer(withMic: false);

    // Create the data channel (only the offerer should do this)
    _dc = await _pc!.createDataChannel(
      'chat',
      RTCDataChannelInit()
        ..ordered = true
        ..maxRetransmits = -1,
    );
    _wireDataChannel();

    final offer = await _pc!.createOffer({
      'offerToReceiveAudio': true,
      'offerToReceiveVideo': false,
    });
    await _pc!.setLocalDescription(offer);

    // Wait briefly to gather ICE candidates into SDP (works OK for demos).
    await Future.delayed(const Duration(seconds: 1));

    final local = await _pc!.getLocalDescription();
    final sdp = jsonEncode({'type': local!.type, 'sdp': local.sdp});
    _localSdpCtrl.text = sdp;
    _logLine('Offer created. Copy & share the Local SDP to the other peer.');
  }

  Future<void> _setRemote() async {
    final txt = _remoteSdpCtrl.text.trim();
    if (txt.isEmpty) return;
    final map = jsonDecode(txt) as Map<String, dynamic>;
    final desc = RTCSessionDescription(
      map['sdp'] as String,
      map['type'] as String,
    );
    await _pc!.setRemoteDescription(desc);
    _logLine('Remote SDP set: ${desc.type}');

    if (desc.type == 'offer') {
      // We are the "answerer"
      final answer = await _pc!.createAnswer({
        'offerToReceiveAudio': true,
        'offerToReceiveVideo': false,
      });
      await _pc!.setLocalDescription(answer);
      await Future.delayed(const Duration(seconds: 1));
      final local = await _pc!.getLocalDescription();
      _localSdpCtrl.text = jsonEncode({'type': local!.type, 'sdp': local.sdp});
      _logLine('Answer created. Share your Local SDP back to the offerer.');
    }
  }

  void _wireDataChannel() {
    _dc?.onMessage = (RTCDataChannelMessage msg) {
      _logLine('Peer: ${msg.text}');
    };
    _dc?.onDataChannelState = (state) {
      _logLine('DataChannel: $state');
    };
  }

  Future<void> _beAnswerer() async {
    await _createPeer(withMic: false);
    _logLine('Ready to paste the remote OFFER and produce an ANSWER.');
  }

  void _sendChat() {
    final txt = _chatCtrl.text.trim();
    if (txt.isEmpty || _dc == null) return;
    _dc!.send(RTCDataChannelMessage(txt));
    _logLine('Me: $txt');
    _chatCtrl.clear();
  }

  @override
  void dispose() {
    _dc?.close();
    _pc?.close();
    _localStream?.dispose();
    _localSdpCtrl.dispose();
    _remoteSdpCtrl.dispose();
    _chatCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('flutter_webrtc P2P demo')),
      body: Padding(
        padding: const EdgeInsets.all(12),
        child: ListView(
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                ElevatedButton(
                  onPressed: _makeOffer,
                  child: const Text('Create OFFER'),
                ),
                ElevatedButton(
                  onPressed: _beAnswerer,
                  child: const Text('Become ANSWERER'),
                ),
                ElevatedButton(
                  onPressed: _setRemote,
                  child: const Text('Set REMOTE (paste below)'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            const Text('Local SDP (share this with peer):'),
            TextField(
              controller: _localSdpCtrl,
              maxLines: 8,
              decoration: const InputDecoration(border: OutlineInputBorder()),
            ),
            const SizedBox(height: 8),
            const Text('Remote SDP (paste what you got from peer):'),
            TextField(
              controller: _remoteSdpCtrl,
              maxLines: 8,
              decoration: const InputDecoration(border: OutlineInputBorder()),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _chatCtrl,
                    decoration: const InputDecoration(
                      hintText: 'Type message…',
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                ElevatedButton(onPressed: _sendChat, child: const Text('Send')),
              ],
            ),
            const SizedBox(height: 12),
            const Text('Log:'),
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                border: Border.all(),
                borderRadius: BorderRadius.circular(6),
              ),
              constraints: const BoxConstraints(minHeight: 120),
              child: Text(_log.join('\n')),
            ),
          ],
        ),
      ),
    );
  }
}
// import 'package:flutter/material.dart';

// import 'callee.dart';

// void main() {
//   runApp(const MainApp());
// }

// class MainApp extends StatelessWidget {
//   const MainApp({super.key});

//   @override
//   Widget build(BuildContext context) {
//     return const MaterialApp(home: AudioCalleePage());
//   }
// }
