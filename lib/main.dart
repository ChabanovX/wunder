import 'dart:convert';
import 'dart:io' show Platform, WebSocket;
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
  // ---------- configurable ----------
  static const String _serverUrl = 'ws://208.123.185.205:8080';
  // ----------------------------------

  RTCPeerConnection? _pc;
  RTCDataChannel? _dc;
  WebSocket? _ws;

  MediaStream? _localStream;

  final _localRenderer = RTCVideoRenderer();
  final _remoteRenderer = RTCVideoRenderer();

  bool _micOn = false;
  bool _camOn = false;
  bool _muted = false;

  // UI
  final _roomCtrl = TextEditingController(); // для join по roomId/ссылке
  final _chatCtrl = TextEditingController();

  String? _roomId;
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
    _roomCtrl.dispose();
    _chatCtrl.dispose();
    _ws?.close();
    super.dispose();
  }

  // --------------------- WebSocket signaling ---------------------

  Future<void> _connectWS() async {
    if (_ws != null) return;
    _logLine('Connecting WS to $_serverUrl …');
    _ws = await WebSocket.connect(_serverUrl);
    _ws!.listen(_onWSMessage, onDone: () {
      _logLine('WS closed');
      _ws = null;
    }, onError: (e) {
      _logLine('WS error: $e');
      _ws = null;
    });
    _logLine('WS connected');
  }

  void _sendWS(Map<String, dynamic> m) {
    final s = jsonEncode(m);
    _ws?.add(s);
  }

  Future<void> _onWSMessage(dynamic data) async {
    final msg = jsonDecode(data as String) as Map<String, dynamic>;
    final type = msg['type'] as String?;

    switch (type) {
      case 'created': // {type:'created', roomId:'...'}
        _roomId = msg['roomId'] as String?;
        _logLine('Room created: $_roomId');
        _logLine('Share link: webrtc://208.123.185.205/$_roomId  (или просто id)');
        setState(() {});
        break;

      case 'offer': // {type:'offer', sdp:'...'}
        if (_pc == null) {
          await _createPeer(withMic: true, withCam: false);
        }
        await _pc!.setRemoteDescription(
          RTCSessionDescription(msg['sdp'] as String, 'offer'),
        );
        _logLine('Remote OFFER set');

        final answer = await _pc!.createAnswer({
          'offerToReceiveAudio': true,
          'offerToReceiveVideo': true,
        });
        await _pc!.setLocalDescription(answer);
        final local = await _pc!.getLocalDescription();
        _sendWS({'type': 'answer', 'sdp': local!.sdp});
        _logLine('ANSWER sent');
        break;

      case 'answer': // {type:'answer', sdp:'...'}
        if (_pc == null) return;
        await _pc!.setRemoteDescription(
          RTCSessionDescription(msg['sdp'] as String, 'answer'),
        );
        _logLine('Remote ANSWER set');
        break;

      case 'ice': // {type:'ice', candidate:{candidate, sdpMid, sdpMLineIndex}}
        if (_pc == null) return;
        final c = msg['candidate'] as Map<String, dynamic>;
        await _pc!.addCandidate(
          RTCIceCandidate(
            c['candidate'] as String?,
            c['sdpMid'] as String?,
            c['sdpMLineIndex'] as int?,
          ),
        );
        break;

      case 'joined': // опционально, если сервер шлёт подтверждение join
        _logLine('Joined room ${msg['roomId']}');
        break;

      default:
        _logLine('WS << ${data.toString()}');
    }
  }

  // --------------------- Peer & media ---------------------

  Future<void> _createPeer({bool withMic = true, bool withCam = false}) async {
    final config = {
      'iceServers': [
        {'urls': 'stun:stun.l.google.com:19302'},
        // Если добавишь TURN — допиши сюда
      ],
      'sdpSemantics': 'unified-plan',
      'iceTransportPolicy': 'all',
      'bundlePolicy': 'max-bundle',
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
      if (cand.candidate != null) {
        _sendWS({
          'type': 'ice',
          'candidate': {
            'candidate': cand.candidate,
            'sdpMid': cand.sdpMid,
            'sdpMLineIndex': cand.sdpMLineIndex,

          }
        });
      }
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
        'video': withCam ? {'facingMode': 'user'} : false,
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

  // ---------- Offerer: create room + send offer via WS ----------
  Future<void> _createRoomAndOffer({bool withMic = true, bool withCam = false}) async {
    await _connectWS();

    // запрос на создание комнаты
    _sendWS({'type': 'create'});

    await _createPeer(withMic: withMic, withCam: withCam);

    // создаём DC сами (offerer)
    _dc = await _pc!.createDataChannel('chat', RTCDataChannelInit()..ordered = true);
    _wireDataChannel();

    final offer = await _pc!.createOffer({
      'offerToReceiveAudio': true,
      'offerToReceiveVideo': true,
    });
    await _pc!.setLocalDescription(offer);
    final local = await _pc!.getLocalDescription();

    // Отправляем оффер
    _sendWS({'type': 'offer', 'sdp': local!.sdp});
    _logLine('OFFER sent via WS');
  }

  // ---------- Answerer: join room ----------
  Future<void> _joinRoomByInput({bool withMic = true, bool withCam = false}) async {
    final raw = _roomCtrl.text.trim();
    if (raw.isEmpty) return;

    // поддержим как "id", так и ссылку вида "webrtc://208.123.185.205/<id>"
    final id = _extractRoomId(raw);
    if (id == null) {
      _logLine('Invalid room code/link');
      return;
    }

    await _connectWS();
    _sendWS({'type': 'join', 'roomId': id});

    await _createPeer(withMic: withMic, withCam: withCam);
    _logLine('Joining room $id …');
  }

  String? _extractRoomId(String raw) {
    final r = raw.trim();
    if (r.startsWith('webrtc://')) {
      // ожидаем "webrtc://host/<id>"
      final parts = r.split('/');
      return parts.isNotEmpty ? parts.last : null;
    }
    if (r.contains('/')) {
      // если прислали "http(s)://.../<id>"
      final parts = r.split('/');
      return parts.isNotEmpty ? parts.last : null;
    }
    return r; // просто id
  }

  // --------------------- Data channel ---------------------

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

  // --------------------- Media controls ---------------------

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

  // --------------------- UI ---------------------

  @override
  Widget build(BuildContext context) {
    final shareLink =
        _roomId == null ? '' : 'webrtc://208.123.185.205/$_roomId';

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
                  onPressed: () => _createRoomAndOffer(withMic: true, withCam: false),
                  child: const Text('Create room (audio)'),
                ),
                ElevatedButton(
                  onPressed: () => _createRoomAndOffer(withMic: true, withCam: true),
                  child: const Text('Create room (audio+video)'),
                ),
                SizedBox(
                  width: 320,
                  child: TextField(
                    controller: _roomCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Room ID or link',
                      hintText: 'вставь id или ссылку',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                ElevatedButton(
                  onPressed: () => _joinRoomByInput(withMic: true, withCam: false),
                  child: const Text('Join (audio)'),
                ),
                ElevatedButton(
                  onPressed: () => _joinRoomByInput(withMic: true, withCam: true),
                  child: const Text('Join (audio+video)'),
                ),
              ],
            ),
            if (_roomId != null) ...[
              const SizedBox(height: 8),
              SelectableText('Room ID: $_roomId'),
              SelectableText('Share link: $shareLink'),
            ],
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
              constraints: const BoxConstraints(minHeight: 160),
              child: Text(_log.join('\n')),
            ),
          ],
        ),
      ),
    );
  }
}
