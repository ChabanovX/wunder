import 'dart:convert';
import 'dart:math';
import 'dart:io' show Platform, WebSocket;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

  // Что хотим слать в 1-м SDP-раунде
  bool _intendMic = false;
  bool _intendCam = false;

  // UI
  final _roomCtrl = TextEditingController();
  final _chatCtrl = TextEditingController();

  // Логи (скролл/копирование/очистка)
  final _log = <String>[];
  final _logScrollCtrl = ScrollController();
  bool _autoScrollLog = true;
  void _logLine(String s) {
    setState(() => _log.add(s));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_autoScrollLog && _logScrollCtrl.hasClients) {
        _logScrollCtrl.jumpTo(_logScrollCtrl.position.maxScrollExtent);
      }
    });
  }

  String? _roomId;

  // ICE
  final _pendingIce = <RTCIceCandidate>[];
  bool _remoteSet = false;

  // Транссиверы
  RTCRtpTransceiver? _audioTx;
  RTCRtpTransceiver? _videoTx;

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
    if (_roomId != null && !m.containsKey('roomId')) m['roomId'] = _roomId;
    _ws?.add(jsonEncode(m));
  }

  Future<void> _onWSMessage(dynamic data) async {
    final msg = jsonDecode(data as String) as Map<String, dynamic>;
    final type = msg['type'] as String?;

    switch (type) {
      case 'created':
      case 'room-created':
        _roomId = (msg['roomId'] ?? msg['id']) as String?;
        _logLine('Room confirmed by server: $_roomId');
        setState(() {});
        break;

      case 'offer':
        if (_pc == null) {
          await _createPeer(withMic: _intendMic, withCam: _intendCam);
        }
        // Локальные треки должны быть готовы ДО Answer
        await _ensureLocalSendReady();

        await _pc!.setRemoteDescription(
          RTCSessionDescription(msg['sdp'] as String, 'offer'),
        );
        _logLine('Remote OFFER set');

        _remoteSet = true;
        for (final c in _pendingIce) {
          await _pc!.addCandidate(c);
        }
        _pendingIce.clear();

        final answer = await _pc!.createAnswer({});
        await _pc!.setLocalDescription(answer);
        final local = await _pc!.getLocalDescription();
        _sendWS({'type': 'answer', 'sdp': local!.sdp});
        _logLine('ANSWER sent');

        Future.delayed(const Duration(seconds: 7), _dumpSelectedIce);
        break;

      case 'answer':
        if (_pc == null) return;
        await _pc!.setRemoteDescription(
          RTCSessionDescription(msg['sdp'] as String, 'answer'),
        );
        _logLine('Remote ANSWER set');

        _remoteSet = true;
        for (final c in _pendingIce) {
          await _pc!.addCandidate(c);
        }
        _pendingIce.clear();

        Future.delayed(const Duration(seconds: 7), _dumpSelectedIce);
        break;

      case 'ice':
        if (_pc == null) return;

        RTCIceCandidate ice;
        if (msg['candidate'] is Map) {
          final c = msg['candidate'] as Map<String, dynamic>;
          ice = RTCIceCandidate(
            c['candidate'] as String?,
            c['sdpMid'] as String?,
            (c['sdpMLineIndex'] as num?)?.toInt(),
          );
        } else {
          ice = RTCIceCandidate(
            msg['candidate'] as String?,
            msg['sdpMid'] as String?,
            (msg['sdpMLineIndex'] as num?)?.toInt(),
          );
        }

        if (_remoteSet) {
          await _pc!.addCandidate(ice);
        } else {
          _pendingIce.add(ice);
        }
        break;

      case 'joined':
        _logLine('Joined room ${msg['roomId']}');
        break;

      default:
        _logLine('WS << ${data.toString()}');
    }
  }

  // --------------------- Peer & media ---------------------

  Future<void> _createPeer({bool withMic = true, bool withCam = false}) async {
    _pendingIce.clear();
    _remoteSet = false;

    _intendMic = withMic;
    _intendCam = withCam;

    final config = {
      'iceServers': [
        {'urls': 'stun:stun.l.google.com:19302'},
        {
          'urls': [
            'turn:208.123.185.205:3478?transport=udp',
            'turn:208.123.185.205:3478?transport=tcp',
            'turn:208.123.185.205:443?transport=tcp',
          ],
          'username': 'webrtc',
          'credential': 'webrtc-pass',
        },
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

    pc.onTrack = (RTCTrackEvent e) async {
      if (e.streams.isNotEmpty) {
        _remoteRenderer.srcObject = e.streams.first;
      } else {
        _remoteRenderer.srcObject ??= await createLocalMediaStream('remote');
        _remoteRenderer.srcObject!.addTrack(e.track);
      }
      _logLine('Remote track: ${e.track.kind}');
      if (mounted) setState(() {});
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
        final preview = cand.candidate!;
        _logLine('ICE >> ${preview.length > 40 ? preview.substring(0, 40) : preview}…');
      }
    };

    pc.onSignalingState = (s) => _logLine('Signaling: $s');
    pc.onIceConnectionState = (s) => _logLine('ICE state: $s');
    pc.onConnectionState = (s) => _logLine('PC state: $s');

    // Объявляем оба m=audio/video заранее
    _audioTx = await _pc!.addTransceiver(
      kind: RTCRtpMediaType.RTCRtpMediaTypeAudio,
      init: RTCRtpTransceiverInit(direction: TransceiverDirection.RecvOnly),
    );
    _videoTx = await _pc!.addTransceiver(
      kind: RTCRtpMediaType.RTCRtpMediaTypeVideo,
      init: RTCRtpTransceiverInit(direction: TransceiverDirection.RecvOnly),
    );

    // Готовим локальные треки до первого SDP
    await _ensureLocalSendReady();
  }

  Future<void> _ensureLocalSendReady() async {
    // Если уже есть локальный стрим — просто синхронизируем состояния
    if (_localStream != null) {
      await _promoteDirections(
        sendAudio: _intendMic && _localStream!.getAudioTracks().isNotEmpty,
        sendVideo: _intendCam && _localStream!.getVideoTracks().isNotEmpty,
      );
      await _ensureLocalPreview();
      return;
    }

    if (!_intendMic && !_intendCam) {
      await _promoteDirections(sendAudio: false, sendVideo: false);
      return;
    }

    // Создаём РОВНО ОДИН локальный стрим
    final s = await navigator.mediaDevices.getUserMedia({
      'audio': _intendMic
          ? {
              'echoCancellation': true,
              'noiseSuppression': true,
              'autoGainControl': true,
            }
          : false,
      'video': _intendCam
          ? {
              'facingMode': 'user',
              'width': {'ideal': 1280},
              'height': {'ideal': 720},
              'frameRate': {'ideal': 30},
            }
          : false,
    });

    _localStream = s;
    _localRenderer.srcObject = _localStream;

    for (final t in s.getTracks()) {
      await _pc!.addTrack(t, s);
    }

    final v = s.getVideoTracks();
    if (v.isNotEmpty) {
      await _bindVideoToSender(v.first);
    }

    _micOn = _intendMic;
    _camOn = _intendCam;
    _muted = false;

    await _promoteDirections(sendAudio: _micOn, sendVideo: _camOn);
    await _ensureLocalPreview();

    _logLine('Local tracks ready for first SDP: ${_micOn ? 'audio ' : ''}${_camOn ? 'video' : ''}');

    if (Platform.isAndroid || Platform.isIOS) {
      await Helper.setSpeakerphoneOn(true);
    }
    if (mounted) setState(() {});
  }

  Future<void> _promoteDirections({required bool sendAudio, required bool sendVideo}) async {
    if (_audioTx != null) {
      await _audioTx!.setDirection(
        sendAudio ? TransceiverDirection.SendRecv : TransceiverDirection.RecvOnly,
      );
    }
    if (_videoTx != null) {
      await _videoTx!.setDirection(
        sendVideo ? TransceiverDirection.SendRecv : TransceiverDirection.RecvOnly,
      );
    }
  }

  Future<void> _ensureLocalPreview() async {
    if (_localStream != null) {
      _localRenderer.srcObject = _localStream;
    }
    final a = _localStream?.getAudioTracks().length ?? 0;
    final v = _localStream?.getVideoTracks().length ?? 0;
    _logLine('Local tracks now => audio:$a video:$v');
  }

  Future<void> _bindVideoToSender(MediaStreamTrack track) async {
    try {
      final senders = await _pc!.getSenders();

      RTCRtpSender? videoSender;

      // 1) уже существующий видео-sender
      for (final s in senders) {
        if (s.track?.kind == 'video') {
          videoSender = s;
          break;
        }
      }
      // 2) пустой sender
      if (videoSender == null) {
        final empty = senders.where((s) => s.track == null);
        if (empty.isNotEmpty) videoSender = empty.first;
      }
      // 3) хоть какой-нибудь
      videoSender ??= senders.isNotEmpty ? senders.first : null;

      if (videoSender != null) {
        await videoSender.replaceTrack(track);
        _logLine('Video track bound via replaceTrack()');
      } else {
        _logLine('No RTCRtpSender available to bind video');
      }
    } catch (e) {
      _logLine('bindVideoToSender error: $e');
    }
  }

  String _genRoomId() {
    final rnd = Random();
    return rnd.nextInt(0x7FFFFFFF).toRadixString(16).padLeft(8, '0');
  }

  // ---------- Offerer ----------
  Future<void> _createRoomAndOffer({bool withMic = true, bool withCam = false}) async {
    _intendMic = withMic;
    _intendCam = withCam;

    await _connectWS();

    _roomId = _genRoomId();
    _logLine('Room created locally: $_roomId');
    setState(() {});

    _sendWS({'type': 'create', 'roomId': _roomId});

    await _createPeer(withMic: withMic, withCam: withCam);

    // DataChannel создаём у офферера
    _dc = await _pc!.createDataChannel('chat', RTCDataChannelInit()..ordered = true);
    _wireDataChannel();

    final offer = await _pc!.createOffer({});
    await _pc!.setLocalDescription(offer);
    final local = await _pc!.getLocalDescription();

    _sendWS({'type': 'offer', 'sdp': local!.sdp});
    _logLine('OFFER sent via WS');
  }

  // ---------- Answerer ----------
  Future<void> _joinRoomByInput({bool withMic = true, bool withCam = false}) async {
    _intendMic = withMic;
    _intendCam = withCam;

    final raw = _roomCtrl.text.trim();
    if (raw.isEmpty) return;

    final id = _extractRoomId(raw);
    if (id == null) {
      _logLine('Invalid room code/link');
      return;
    }

    await _connectWS();

    _roomId = id;
    setState(() {});

    _sendWS({'type': 'join', 'roomId': id});

    await _createPeer(withMic: withMic, withCam: withCam);
    _logLine('Joining room $id …');
  }

  String? _extractRoomId(String raw) {
    final r = raw.trim();
    if (r.startsWith('webrtc://')) {
      final parts = r.split('/');
      return parts.isNotEmpty ? parts.last : null;
    }
    if (r.contains('/')) {
      final parts = r.split('/');
      return parts.isNotEmpty ? parts.last : null;
    }
    return r;
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

    // Уже есть — просто включим
    final existing = _localStream?.getAudioTracks() ?? const <MediaStreamTrack>[];
    if (existing.isNotEmpty) {
      for (final t in existing) t.enabled = true;
      _micOn = true;
      _muted = false;
      await _promoteDirections(sendAudio: true, sendVideo: _camOn);
      await _ensureLocalPreview();
      setState(() {});
      _logLine('Mic resumed');
      return;
    }

    final s = await navigator.mediaDevices.getUserMedia({'audio': true, 'video': false});
    final track = s.getAudioTracks().first;

    _localStream ??= await createLocalMediaStream('local');
    _localStream!.addTrack(track);
    _localRenderer.srcObject = _localStream;

    await _pc!.addTrack(track, _localStream!);

    _micOn = true; _muted = false;
    await _promoteDirections(sendAudio: true, sendVideo: _camOn);
    await _ensureLocalPreview();
    setState(() {});
    _logLine('Mic started');
  }

  Future<void> _stopMic() async {
    final a = _localStream?.getAudioTracks().toList() ?? [];
    for (final t in a) {
      await t.stop();
      _localStream?.removeTrack(t);
    }
    _micOn = false;
    await _promoteDirections(sendAudio: false, sendVideo: _camOn);
    _maybeCleanupLocalStream();
    await _ensureLocalPreview();
    setState(() {});
    _logLine('Mic stopped');
  }

  Future<void> _startCam() async {
    if (_pc == null) return;

    // Уже есть видео — включим
    final existing = _localStream?.getVideoTracks() ?? const <MediaStreamTrack>[];
    if (existing.isNotEmpty) {
      for (final t in existing) t.enabled = true;
      _camOn = true;
      await _promoteDirections(sendAudio: _micOn, sendVideo: true);
      await _ensureLocalPreview();
      setState(() {});
      _logLine('Camera resumed');
      return;
    }

    // Тянем новый временный стрим, берём из него трек
    final tmp = await navigator.mediaDevices.getUserMedia({
      'audio': false,
      'video': {
        'facingMode': 'user',
        'width': {'ideal': 1280},
        'height': {'ideal': 720},
        'frameRate': {'ideal': 30},
      },
    });
    final track = tmp.getVideoTracks().first;

    // подчистим прежние видео-треки
    final old = _localStream?.getVideoTracks().toList() ?? [];
    for (final t in old) {
      await t.stop();
      _localStream?.removeTrack(t);
    }

    _localStream ??= await createLocalMediaStream('local');
    _localStream!.addTrack(track);

    await _bindVideoToSender(track);
    _localRenderer.srcObject = _localStream;

    await _pc!.addTrack(track, _localStream!);

    _camOn = true;
    await _promoteDirections(sendAudio: _micOn, sendVideo: true);
    await _ensureLocalPreview();
    setState(() {});
    _logLine('Camera started');
  }

  Future<void> _stopCam() async {
    final v = _localStream?.getVideoTracks().toList() ?? [];
    for (final t in v) {
      await t.stop();
      _localStream?.removeTrack(t);
    }
    _camOn = false;
    await _promoteDirections(sendAudio: _micOn, sendVideo: false);
    _maybeCleanupLocalStream();
    await _ensureLocalPreview();
    setState(() {});
    _logLine('Camera stopped');
  }

  void _maybeCleanupLocalStream() {
    if (_localStream == null) return;
    if (_localStream!.getTracks().isEmpty) {
      _localRenderer.srcObject = null;
      _localStream!.dispose();
      _localStream = null;
    } else {
      _localRenderer.srcObject = _localStream;
    }
  }

  Future<void> _switchCamera() async {
    final v = _localStream?.getVideoTracks();
    if (v == null || v.isEmpty) return;
    await Helper.switchCamera(v.first);
    _logLine('Camera switched');
  }

  // --------------------- ICE debug ---------------------

  Future<void> _dumpSelectedIce() async {
    if (_pc == null) return;
    try {
      final stats = await _pc!.getStats();
      final byId = {for (final r in stats) r.id: r};

      for (final r in stats) {
        if (r.type == 'candidate-pair' &&
            ((r.values['selected'] == true) || (r.values['state'] == 'succeeded'))) {
          final local = byId[r.values['localCandidateId']];
          final remote = byId[r.values['remoteCandidateId']];

          final lt = local?.values['candidateType'];
          final rt = remote?.values['candidateType'];
          final lp = local?.values['protocol'];
          final rp = remote?.values['protocol'];

          _logLine('ICE PAIR => local:$lt/$lp  remote:$rt/$rp');
          _logLine('ICE BYTES => sent:${r.values['bytesSent']} recv:${r.values['bytesReceived']}');
        }
      }
    } catch (e) {
      _logLine('ICE stats error: $e');
    }
  }

  // --------------------- UI ---------------------

  @override
  Widget build(BuildContext context) {
    final shareLink = _roomId == null ? '' : 'webrtc://208.123.185.205/$_roomId';

    return Scaffold(
      appBar: AppBar(title: const Text('flutter_webrtc P2P demo')),
      body: Padding(
        padding: const EdgeInsets.all(12),
        child: ListView(
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
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

            // Видео окна
            Row(
              children: [
                Expanded(
                  child: AspectRatio(
                    aspectRatio: 16 / 9,
                    child: Container(
                      decoration: BoxDecoration(border: Border.all()),
                      child: RTCVideoView(
                        _localRenderer,
                        mirror: true,
                        objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitCover,
                      ),
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
                    decoration: const InputDecoration(hintText: 'Type message…'),
                  ),
                ),
                const SizedBox(width: 8),
                ElevatedButton(onPressed: _sendChat, child: const Text('Send')),
              ],
            ),

            const SizedBox(height: 12),

            // Логи + действия
            Row(
              children: [
                const Text('Log:', style: TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(width: 8),
                TextButton(
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: _log.join('\n')));
                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Logs copied to clipboard')),
                      );
                    }
                  },
                  child: const Text('Copy'),
                ),
                TextButton(
                  onPressed: () => setState(() => _log.clear()),
                  child: const Text('Clear'),
                ),
                TextButton(
                  onPressed: _dumpSelectedIce,
                  child: const Text('Dump ICE now'),
                ),
                TextButton(
                  onPressed: _ensureLocalPreview,
                  child: const Text('Fix Preview'),
                ),
                const Spacer(),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text('Auto-scroll'),
                    Switch(
                      value: _autoScrollLog,
                      onChanged: (v) => setState(() => _autoScrollLog = v),
                    ),
                  ],
                ),
              ],
            ),
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                border: Border.all(),
                borderRadius: BorderRadius.circular(6),
              ),
              constraints: const BoxConstraints(minHeight: 160, maxHeight: 260),
              child: Scrollbar(
                controller: _logScrollCtrl,
                thumbVisibility: true,
                child: SingleChildScrollView(
                  controller: _logScrollCtrl,
                  child: SelectableText(_log.join('\n')),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
