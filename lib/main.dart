import 'dart:convert';
import 'dart:io' show Platform;
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

  // Video renderers
  final _localRenderer = RTCVideoRenderer();
  final _remoteRenderer = RTCVideoRenderer();

  // UI / state
  bool _micOn = false;
  bool _camOn = false;
  bool _muted = false;

  // Text controllers
  final _localSdpCtrl = TextEditingController();
  final _remoteSdpCtrl = TextEditingController();
  final _chatCtrl = TextEditingController();

  final _log = <String>[];
  void _logLine(String s) => setState(() => _log.add(s));

  @override
  void initState() {
    super.initState();
    _localRenderer.initialize();
    _remoteRenderer.initialize();
  }

  @override
  void dispose() {
    _dc?.close();
    _pc?.close();
    _localStream?.dispose();
    _localRenderer.dispose();
    _remoteRenderer.dispose();
    _localSdpCtrl.dispose();
    _remoteSdpCtrl.dispose();
    _chatCtrl.dispose();
    super.dispose();
  }

  // ---- Peer & media ----

  Future<void> _createPeer({bool withMic = true, bool withCam = false}) async {
    final config = {
      'iceServers': [
        // Для одной Wi-Fi сети можно пусто; для интернета добавь STUN/TURN
        // {'urls': 'stun:stun.l.google.com:19302'},
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

    pc.onTrack = (RTCTrackEvent e) {
      if (e.streams.isNotEmpty) {
        _remoteRenderer.srcObject = e.streams.first;
        _logLine('Remote track: ${e.track.kind}');
      } else {
        _logLine('Remote track w/o stream: ${e.track.kind}');
      }
    };

    pc.onDataChannel = (RTCDataChannel dc) {
      _dc = dc;
      _wireDataChannel();
      _logLine('DataChannel received: ${dc.label}');
    };

    pc.onIceCandidate = (cand) {
      _logLine('ICE: ${cand.candidate?.substring(0, 30)}…');
    };

    pc.onConnectionState = (state) {
      _logLine('PC state: $state');
    };

    if (withMic || withCam) {
      final media = await navigator.mediaDevices.getUserMedia({
        'audio': {
          'echoCancellation': true,
          'noiseSuppression': true,
          'autoGainControl': true,
        },
        'video': withCam
            ? {
                'facingMode': 'user',
              }
            : false,
      });

      _localStream = media;
      _micOn = withMic;
      _camOn = withCam;
      _muted = false;

      _localRenderer.srcObject = media;

      for (final t in media.getTracks()) {
        await pc.addTrack(t, media);
      }
      _logLine('Local tracks added: '
          '${withMic ? 'audio ' : ''}${withCam ? 'video' : ''}');

      if (Platform.isAndroid || Platform.isIOS) {
        await Helper.setSpeakerphoneOn(true);
      }
      setState(() {});
    }
  }

  Future<void> _makeOffer({bool withMic = true, bool withCam = false}) async {
    await _createPeer(withMic: withMic, withCam: withCam);

    _dc = await _pc!.createDataChannel(
      'chat',
      RTCDataChannelInit()..ordered = true,
    );
    _wireDataChannel();

    final offer = await _pc!.createOffer({
      'offerToReceiveAudio': true,
      'offerToReceiveVideo': true,
    });
    await _pc!.setLocalDescription(offer);

    // Соберём ICE в SDP для ручного обмена
    await Future.delayed(const Duration(seconds: 1));

    final local = await _pc!.getLocalDescription();
    _localSdpCtrl.text = jsonEncode({'type': local!.type, 'sdp': local.sdp});
    _logLine('Offer created. Share Local SDP with peer.');
  }

  Future<void> _beAnswerer({bool withMic = true, bool withCam = false}) async {
    await _createPeer(withMic: withMic, withCam: withCam);
    _logLine('Answerer ready. Paste remote OFFER, then press Set REMOTE.');
  }

  Future<void> _setRemote() async {
    final txt = _remoteSdpCtrl.text.trim();
    if (txt.isEmpty || _pc == null) return;
    final map = jsonDecode(txt) as Map<String, dynamic>;
    final desc = RTCSessionDescription(map['sdp'] as String, map['type'] as String);

    await _pc!.setRemoteDescription(desc);
    _logLine('Remote SDP set: ${desc.type}');

    if (desc.type == 'offer') {
      final answer = await _pc!.createAnswer({
        'offerToReceiveAudio': true,
        'offerToReceiveVideo': true,
      });
      await _pc!.setLocalDescription(answer);
      await Future.delayed(const Duration(seconds: 1));
      final local = await _pc!.getLocalDescription();
      _localSdpCtrl.text = jsonEncode({'type': local!.type, 'sdp': local.sdp});
      _logLine('Answer created. Send back to offerer.');
    }
  }

  // ---- Data channel ----

  void _wireDataChannel() {
    _dc?.onMessage = (RTCDataChannelMessage msg) {
      _logLine('Peer: ${msg.text}');
    };
    _dc?.onDataChannelState = (state) {
      _logLine('DataChannel: $state');
    };
  }

  void _sendChat() {
    final txt = _chatCtrl.text.trim();
    if (txt.isEmpty || _dc == null) return;
    _dc!.send(RTCDataChannelMessage(txt));
    _logLine('Me: $txt');
    _chatCtrl.clear();
  }

  // ---- Media controls ----

  void _toggleMute() {
    final tracks = _localStream?.getAudioTracks();
    if (tracks == null || tracks.isEmpty) return;
    _muted = !_muted;
    for (final t in tracks) {
      t.enabled = !_muted;
    }
    _logLine(_muted ? 'Mic muted' : 'Mic unmuted');
    setState(() {});
  }

  Future<void> _startMic() async {
    if (_pc == null) return;
    final s = await navigator.mediaDevices.getUserMedia({'audio': true, 'video': false});
    final track = s.getAudioTracks().first;
    await _pc!.addTrack(track, s);
    if (_localStream == null) {
      _localStream = s;
      _localRenderer.srcObject = _localStream;
    } else {
      _localStream!.addTrack(track);
    }
    _micOn = true;
    _muted = false;
    setState(() {});
    _logLine('Mic started');
  }

  Future<void> _stopMic() async {
    final a = _localStream?.getAudioTracks();
    if (a != null) {
      for (final t in a) {
        await t.stop();
        _localStream!.removeTrack(t);
      }
    }
    _micOn = false;
    setState(() {});
    _logLine('Mic stopped');
  }

  Future<void> _startCam() async {
    if (_pc == null) return;
    final s = await navigator.mediaDevices.getUserMedia({'audio': false, 'video': true});
    final track = s.getVideoTracks().first;
    await _pc!.addTrack(track, s);
    if (_localStream == null) {
      _localStream = s;
    } else {
      _localStream!.addTrack(track);
    }
    _localRenderer.srcObject = _localStream;
    _camOn = true;
    setState(() {});
    _logLine('Camera started');
  }

  Future<void> _stopCam() async {
    final v = _localStream?.getVideoTracks();
    if (v != null) {
      for (final t in v) {
        await t.stop();
        _localStream!.removeTrack(t);
      }
    }
    _camOn = false;
    setState(() {});
    _logLine('Camera stopped');
  }

  Future<void> _switchCamera() async {
    final v = _localStream?.getVideoTracks();
    if (v == null || v.isEmpty) return;
    await Helper.switchCamera(v.first);
    _logLine('Camera switched');
  }

  // ---- UI ----

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
                  onPressed: () => _makeOffer(withMic: true, withCam: false),
                  child: const Text('Create OFFER (audio)'),
                ),
                ElevatedButton(
                  onPressed: () => _makeOffer(withMic: true, withCam: true),
                  child: const Text('Create OFFER (audio+video)'),
                ),
                ElevatedButton(
                  onPressed: () => _beAnswerer(withMic: true, withCam: false),
                  child: const Text('Become ANSWERER (audio)'),
                ),
                ElevatedButton(
                  onPressed: () => _beAnswerer(withMic: true, withCam: true),
                  child: const Text('Become ANSWERER (audio+video)'),
                ),
                ElevatedButton(
                  onPressed: _setRemote,
                  child: const Text('Set REMOTE (paste below)'),
                ),
              ],
            ),
            const SizedBox(height: 12),

            // Media controls
            Wrap(
              spacing: 8,
              children: [
                ElevatedButton(
                  onPressed: _micOn ? _stopMic : _startMic,
                  child: Text(_micOn ? 'Stop Mic' : 'Start Mic'),
                ),
                ElevatedButton(
                  onPressed: _toggleMute,
                  child: Text(_muted ? 'Unmute' : 'Mute'),
                ),
                ElevatedButton(
                  onPressed: _camOn ? _stopCam : _startCam,
                  child: Text(_camOn ? 'Stop Cam' : 'Start Cam'),
                ),
                ElevatedButton(
                  onPressed: _switchCamera,
                  child: const Text('Switch Camera'),
                ),
                if (Platform.isAndroid || Platform.isIOS)
                  ElevatedButton(
                    onPressed: () => Helper.setSpeakerphoneOn(true),
                    child: const Text('Speaker On'),
                  ),
              ],
            ),

            const SizedBox(height: 12),

            // Video views
            Row(
              children: [
                Expanded(
                  child: AspectRatio(
                    aspectRatio: 16 / 9,
                    child: Container(
                      decoration: BoxDecoration(border: Border.all()),
                      child: RTCVideoView(_localRenderer, mirror: true),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: AspectRatio(
                    aspectRatio: 16 / 9,
                    child: Container(
                      decoration: BoxDecoration(border: Border.all()),
                      child: RTCVideoView(_remoteRenderer),
                    ),
                  ),
                ),
              ],
            ),

            const SizedBox(height: 12),

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
                    decoration: const InputDecoration(hintText: 'Type message…'),
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
