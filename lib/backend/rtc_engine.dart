// lib/backend/rtc_engine.dart
import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform, WebSocket;
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:http/http.dart' as http;

/// Единый движок: WebRTC + сигналинг WebSocket + TURN.
/// Управляет:
/// - созданием/входом в комнату
/// - обменом SDP/ICE
/// - локальными треками (микрофон/камера)
/// - DataChannel (чат)
/// UI получает только renderers, ValueNotifier'ы и методы управления.
class WebRTCEngine {
  // ---------- конфиг ----------
  final String wsUrl;     // ws://host:8080
  final String apiBase;   // http://host:8000
  final String userId;    // demo-device
  WebRTCEngine({
    required this.wsUrl,
    required this.apiBase,
    required this.userId,
  });

  // ---------- внешнее API для UI ----------
  final RTCVideoRenderer localRenderer = RTCVideoRenderer();
  final RTCVideoRenderer remoteRenderer = RTCVideoRenderer();

  final ValueNotifier<String?> roomId = ValueNotifier<String?>(null);
  final ValueNotifier<bool> micOn = ValueNotifier<bool>(false);
  final ValueNotifier<bool> camOn = ValueNotifier<bool>(false);
  final ValueNotifier<bool> muted = ValueNotifier<bool>(false);
  final ValueNotifier<bool> connected = ValueNotifier<bool>(false);
  final ValueNotifier<List<String>> logs = ValueNotifier<List<String>>([]);

  // chat
  final StreamController<String> _chatIn = StreamController.broadcast();
  Stream<String> get chatStream => _chatIn.stream;

  // управление желаемыми состояниями (что хотим слать в первом SDP)
  bool _intendMic = false;
  bool _intendCam = false;

  // внутреннее
  RTCPeerConnection? _pc;
  RTCDataChannel? _dc;
  WebSocket? _ws;
  MediaStream? _localStream;

  // ICE
  final _pendingIce = <RTCIceCandidate>[];
  bool _remoteSet = false;

  // senders (для addTrack один раз)
  RTCRtpSender? _audioSender;
  RTCRtpSender? _videoSender;

  // TURN
  List<Map<String, dynamic>> _apiIce = [];

  // util
  void _log(String s) {
    final next = List<String>.from(logs.value)..add(s);
    logs.value = next;
  }

  Future<void> init() async {
    await localRenderer.initialize();
    await remoteRenderer.initialize();
  }

  Future<void> dispose() async {
    try { await _dc?.close(); } catch (_) {}
    try { await _pc?.close(); } catch (_) {}
    try { await _localStream?.dispose(); } catch (_) {}
    try { await localRenderer.dispose(); } catch (_) {}
    try { await remoteRenderer.dispose(); } catch (_) {}
    try { await _ws?.close(); } catch (_) {}
    await _chatIn.close();
  }

  // --------------------- Public UI methods ---------------------

  Future<void> createRoom({bool withMic = true, bool withCam = false}) async {
    _intendMic = withMic;
    _intendCam = withCam;

    await _ensureWS();
    final id = _genRoomId();
    roomId.value = id;
    _log('Room created locally: $id');

    _sendWS({'type': 'create', 'roomId': id});

    await _createPeer();
    await _ensureLocalSendReady(); // локальные треки ДО offer

    _dc = await _pc!.createDataChannel('chat', RTCDataChannelInit()..ordered = true);
    _wireDataChannel();

    await _makeOffer();
    Future.delayed(const Duration(seconds: 7), dumpSelectedIce);
  }

  Future<void> joinRoom(String raw, {bool withMic = true, bool withCam = false}) async {
    final id = _extractRoomId(raw);
    if (id == null || id.isEmpty) {
      _log('Invalid room code/link');
      return;
    }

    _intendMic = withMic;
    _intendCam = withCam;

    await _ensureWS();
    roomId.value = id;

    _sendWS({'type': 'join', 'roomId': id});

    await _createPeer();
    _log('Joining room $id …');
  }

  void sendChat(String text) {
    if (text.trim().isEmpty || _dc == null) return;
    _dc!.send(RTCDataChannelMessage(text));
    _log('Me: $text');
  }

  Future<void> startMic() async {
    _intendMic = true;
    await _ensureLocalSendReady();
    _log('Mic started/resumed');
  }

  Future<void> stopMic() async {
    final a = _localStream?.getAudioTracks().toList() ?? [];
    for (final t in a) t.enabled = false;
    _intendMic = false;
    micOn.value = false;
    muted.value = true;
    _log('Mic stopped');
  }

  void toggleMute() {
    final tracks = _localStream?.getAudioTracks();
    if (tracks == null || tracks.isEmpty) return;
    final nextMuted = !muted.value;
    for (final t in tracks) t.enabled = !nextMuted;
    muted.value = nextMuted;
    _log(nextMuted ? 'Mic muted' : 'Mic unmuted');
  }

  Future<void> startCam() async {
    _intendCam = true;
    await _ensureLocalSendReady();
    _log('Camera started/resumed');
  }

  Future<void> stopCam() async {
    final v = _localStream?.getVideoTracks().toList() ?? [];
    for (final t in v) t.enabled = false;
    _intendCam = false;
    camOn.value = false;
    _log('Camera stopped');
  }

  Future<void> switchCamera() async {
    final v = _localStream?.getVideoTracks();
    if (v == null || v.isEmpty) return;
    await Helper.switchCamera(v.first);
    _log('Camera switched');
  }

  Future<void> dumpSelectedIce() async {
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

          _log('ICE PAIR => local:$lt/$lp  remote:$rt/$rp');
          _log('ICE BYTES => sent:${r.values['bytesSent']} recv:${r.values['bytesReceived']}');
        }
      }
    } catch (e) {
      _log('ICE stats error: $e');
    }
  }

  // --------------------- internals ---------------------

  Future<void> _ensureWS() async {
    if (_ws != null) return;
    _log('Connecting WS to $wsUrl …');
    _ws = await WebSocket.connect(wsUrl);
    _ws!.listen(_onWSMessage, onDone: () {
      _log('WS closed');
      _ws = null;
    }, onError: (e) {
      _log('WS error: $e');
      _ws = null;
    });
    _log('WS connected');
  }

  void _sendWS(Map<String, dynamic> m) {
    final id = roomId.value;
    if (id != null && !m.containsKey('roomId')) m['roomId'] = id;
    _ws?.add(jsonEncode(m));
  }

  Future<void> _onWSMessage(dynamic data) async {
    final msg = jsonDecode(data as String) as Map<String, dynamic>;
    final type = msg['type'] as String?;

    switch (type) {
      case 'created':
      case 'room-created':
        roomId.value = (msg['roomId'] ?? msg['id']) as String?;
        _log('Room confirmed by server: ${roomId.value}');
        break;

      case 'offer':
        if (_pc == null) await _createPeer();
        await _pc!.setRemoteDescription(
          RTCSessionDescription(msg['sdp'] as String, 'offer'),
        );
        _log('Remote OFFER set');
        _remoteSet = true;

        await _ensureLocalSendReady(); // ДО answer

        for (final c in _pendingIce) { await _pc!.addCandidate(c); }
        _pendingIce.clear();

        final answer = await _pc!.createAnswer({});
        await _pc!.setLocalDescription(answer);
        final local = await _pc!.getLocalDescription();
        _sendWS({'type': 'answer', 'sdp': local!.sdp});
        _log('ANSWER sent');

        Future.delayed(const Duration(seconds: 7), dumpSelectedIce);
        break;

      case 'answer':
        if (_pc == null) return;
        await _pc!.setRemoteDescription(
          RTCSessionDescription(msg['sdp'] as String, 'answer'),
        );
        _log('Remote ANSWER set');
        _remoteSet = true;

        for (final c in _pendingIce) { await _pc!.addCandidate(c); }
        _pendingIce.clear();

        Future.delayed(const Duration(seconds: 7), dumpSelectedIce);
        break;

      case 'ice':
        if (_pc == null) return;
        final obj = msg['candidate'];
        RTCIceCandidate ice;
        if (obj is Map) {
          ice = RTCIceCandidate(
            obj['candidate'] as String?,
            obj['sdpMid'] as String?,
            (obj['sdpMLineIndex'] as num?)?.toInt(),
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

      case 'peer-joined':
        _log('Peer joined: ${msg['peerId']}');
        break;

      case 'joined':
        _log('Joined room ${msg['roomId']}');
        break;

      default:
        _log('WS << ${data.toString()}');
    }
  }

  Future<void> _createPeer() async {
    _pendingIce.clear();
    _remoteSet = false;

    _apiIce = await _fetchIceServers(userId);

    final pc = await createPeerConnection(_buildRtcConfig(), {
      'mandatory': {},
      'optional': [
        {'DtlsSrtpKeyAgreement': true},
      ],
    });
    _pc = pc;

    pc.onTrack = (RTCTrackEvent e) async {
      if (e.streams.isNotEmpty) {
        remoteRenderer.srcObject = e.streams.first;
      } else {
        remoteRenderer.srcObject ??= await createLocalMediaStream('remote');
        remoteRenderer.srcObject!.addTrack(e.track);
      }
      _log('Remote track: ${e.track.kind}');
    };

    pc.onDataChannel = (RTCDataChannel dc) {
      _dc = dc;
      _wireDataChannel();
      _log('DataChannel received: ${dc.label}');
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
        _log('ICE >> ${preview.length > 40 ? preview.substring(0, 40) : preview}…');
      }
    };

    pc.onSignalingState = (s) => _log('Signaling: $s');
    pc.onIceConnectionState = (s) {
      _log('ICE state: $s');
      connected.value = (s == RTCIceConnectionState.RTCIceConnectionStateConnected ||
                         s == RTCIceConnectionState.RTCIceConnectionStateCompleted);
    };
    pc.onConnectionState = (s) => _log('PC state: $s');
  }

  Future<List<Map<String, dynamic>>> _fetchIceServers(String uid) async {
    final uri = Uri.parse('$apiBase/turn/credentials?user_id=$uid');
    final resp = await http.get(uri).timeout(const Duration(seconds: 7));
    if (resp.statusCode != 200) {
      _log('TURN creds error: ${resp.statusCode} ${resp.body}');
      throw Exception('TURN creds error');
    }
    final body = jsonDecode(resp.body) as Map<String, dynamic>;
    final list = (body['iceServers'] as List).cast<Map<String, dynamic>>();

    String? uName;
    String? uCred;
    for (final s in list) {
      if (s.containsKey('username') && s.containsKey('credential')) {
        uName ??= s['username'] as String?;
        uCred ??= s['credential'] as String?;
      }
      _log('ICE from API: ${s['urls']} user=${s['username'] ?? '-'}');
    }
    if (uName != null && uCred != null) {
      final has443 = list.any((s) {
        final urls = s['urls'];
        if (urls is String) return urls.startsWith('turn:') && urls.contains(':443?transport=tcp');
        if (urls is List) return urls.any((e) => (e as String).startsWith('turn:') && e.contains(':443?transport=tcp'));
        return false;
      });
      if (!has443) {
        list.add({
          'urls': ['turn:208.123.185.205:443?transport=tcp'],
          'username': uName,
          'credential': uCred,
        });
        _log('ICE added: turn:208.123.185.205:443?transport=tcp (same creds)');
      }
    }
    return list;
  }

  Map<String, dynamic> _buildRtcConfig() {
    return {
      'iceServers': [
        {'urls': 'stun:stun.l.google.com:19302'},
        ..._apiIce,
      ],
      'sdpSemantics': 'unified-plan',
      'iceTransportPolicy': 'all',
      'bundlePolicy': 'max-bundle',
    };
  }

  Future<void> _ensureLocalSendReady() async {
    if (_localStream == null && (_intendMic || _intendCam)) {
      _localStream = await createLocalMediaStream('local');
    }

    // MIC
    if (_intendMic) {
      if ((_localStream?.getAudioTracks().isEmpty ?? true)) {
        final s = await navigator.mediaDevices.getUserMedia({'audio': true, 'video': false});
        final track = s.getAudioTracks().first;
        _localStream!.addTrack(track);
        _audioSender ??= await _pc!.addTrack(track, _localStream!);
      } else {
        for (final t in _localStream!.getAudioTracks()) t.enabled = true;
      }
      micOn.value = true;
      muted.value = false;
    }

    // CAM
    if (_intendCam) {
      if ((_localStream?.getVideoTracks().isEmpty ?? true)) {
        final tmp = await navigator.mediaDevices.getUserMedia({
          'audio': false,
          'video': {
            'facingMode': 'user',
            'width': {'ideal': 1280},
            'height': {'ideal': 720},
            'frameRate': {'ideal': 30},
          },
        });
        final vTrack = tmp.getVideoTracks().first;
        _localStream!.addTrack(vTrack);
        _videoSender ??= await _pc!.addTrack(vTrack, _localStream!);
      } else {
        for (final t in _localStream!.getVideoTracks()) t.enabled = true;
      }
      camOn.value = true;
    }

    if (_localStream != null) {
      localRenderer.srcObject = _localStream;
    }

    _log('Local tracks now => audio:${_localStream?.getAudioTracks().length ?? 0} '
         'video:${_localStream?.getVideoTracks().length ?? 0}');

    if (Platform.isAndroid || Platform.isIOS) {
      await Helper.setSpeakerphoneOn(true);
    }
  }

  void _wireDataChannel() {
    _dc?.onMessage = (RTCDataChannelMessage msg) {
      _chatIn.add(msg.text);
      _log('Peer: ${msg.text}');
    };
    _dc?.onDataChannelState = (state) {
      _log('DataChannel: $state');
    };
  }

  Future<void> _makeOffer() async {
    final offer = await _pc!.createOffer({
      'offerToReceiveAudio': 1,
      'offerToReceiveVideo': 1,
    });
    await _pc!.setLocalDescription(offer);
    final local = await _pc!.getLocalDescription();
    _sendWS({'type': 'offer', 'sdp': local!.sdp});
    _log('OFFER sent via WS');
  }

  String _genRoomId() {
    final rnd = Random();
    return rnd.nextInt(0x7FFFFFFF).toRadixString(16).padLeft(8, '0');
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
}
