// lib/backend/rtc_engine.dart
// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

import '../config/env.dart';

/// WebRTC движок: PeerConnection + WebSocket-сигналинг + TURN.
class WebRTCEngine {
  // ---------- конфиг ----------
  final String wsUrl;   // напр.: wss://signal.wundercalls.ru/ws
  final String apiBase; // напр.: https://api.wundercalls.ru
  final String userId;

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

  // чат
  final _chatIn = StreamController<String>.broadcast();
  Stream<String> get chatStream => _chatIn.stream;

  // желаемые состояния (какие треки хотим слать)
  bool _intendMic = false;
  bool _intendCam = false;

  // внутреннее
  RTCPeerConnection? _pc;
  RTCDataChannel? _dc;
  WebSocketChannel? _wsChan;
  MediaStream? _localStream;

  // ICE
  final _pendingIce = <RTCIceCandidate>[];
  bool _remoteSet = false;

  // senders
  RTCRtpSender? _audioSender;
  RTCRtpSender? _videoSender;

  // адресный сигналинг
  String? _myPeerId;
  String? _remotePeerId;

  // ICE-серверы с API
  List<Map<String, dynamic>> _apiIce = [];

  // гонки
  bool _makingAnswer = false;
  bool _negotiationInFlight = false;

  // утиль логов
  void _log(String s) => logs.value = [...logs.value, s];

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
    try { await _wsChan?.sink.close(); } catch (_) {}
    _wsChan = null;
    await _chatIn.close();
    _myPeerId = null;
    _remotePeerId = null;
  }

  // --------------------- Public API ---------------------

  /// Создать комнату (обычно хост). По умолчанию: mic=on, cam=off.
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

  /// Присоединиться к комнате (обычно гость). Рекомендуется mic=on, cam=off.
  Future<void> joinRoom(
    String raw, {
    bool withMic = true,
    bool withCam = false,
  }) async {
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

    // Создаём локальные треки сразу (браузер спросит доступ при необходимости).
    await _ensureLocalSendReady();

    // Если камеру стартуем "выключенной" — трек есть, но disabled.
    if (!_intendCam) {
      for (final t in _localStream?.getVideoTracks() ?? const []) {
        t.enabled = false;
      }
      camOn.value = false;
      _log('Camera slot prepared but disabled (waiting for user action)');
    }

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

    // найдём/включим аудио-транссивер
    final txs = await _pc?.getTransceivers() ?? [];
    RTCRtpTransceiver? atx;
    for (final t in txs) {
      final kind = t.receiver.track?.kind ?? t.sender.track?.kind;
      if (kind == 'audio') { atx = t; break; }
    }
    atx ??= await _pc!.addTransceiver(
      kind: RTCRtpMediaType.RTCRtpMediaTypeAudio,
      init: RTCRtpTransceiverInit(direction: TransceiverDirection.SendRecv),
    );
    await atx.setDirection(TransceiverDirection.SendRecv);

    final aTracks = _localStream?.getAudioTracks() ?? const [];
    if (aTracks.isNotEmpty) {
      await atx.sender.replaceTrack(aTracks.first);
      _audioSender ??= atx.sender;
    }

    micOn.value = true;
    muted.value = false;
    _log('Mic started/resumed');
    await _renegotiate('startMic');
  }

  Future<void> stopMic() async {
    for (final t in _localStream?.getAudioTracks().toList() ?? const []) {
      t.enabled = false;
    }

    final txs = await _pc?.getTransceivers() ?? [];
    for (final t in txs) {
      final kind = t.receiver.track?.kind ?? t.sender.track?.kind;
      if (kind == 'audio') {
        await t.sender.replaceTrack(null);
        await t.setDirection(TransceiverDirection.RecvOnly);
        break;
      }
    }

    _intendMic = false;
    micOn.value = false;
    muted.value = true;
    _log('Mic stopped');
    await _renegotiate('stopMic');
  }

  Future<void> startCam() async {
    _intendCam = true;
    await _ensureLocalSendReady();

    final txs = await _pc?.getTransceivers() ?? [];
    RTCRtpTransceiver? vtx;
    for (final t in txs) {
      final kind = t.receiver.track?.kind ?? t.sender.track?.kind;
      if (kind == 'video') { vtx = t; break; }
    }
    vtx ??= await _pc!.addTransceiver(
      kind: RTCRtpMediaType.RTCRtpMediaTypeVideo,
      init: RTCRtpTransceiverInit(direction: TransceiverDirection.SendRecv),
    );
    await vtx.setDirection(TransceiverDirection.SendRecv);

    final vTracks = _localStream?.getVideoTracks() ?? const [];
    if (vTracks.isNotEmpty) {
      vTracks.first.enabled = true;
      await vtx.sender.replaceTrack(vTracks.first);
      _videoSender ??= vtx.sender;
    }

    camOn.value = true;
    _log('Camera started/resumed');
    await _renegotiate('startCam');
  }

  Future<void> stopCam() async {
    for (final t in _localStream?.getVideoTracks().toList() ?? const []) {
      t.enabled = false;
    }

    final txs = await _pc?.getTransceivers() ?? [];
    for (final t in txs) {
      final kind = t.receiver.track?.kind ?? t.sender.track?.kind;
      if (kind == 'video') {
        await t.sender.replaceTrack(null);
        await t.setDirection(TransceiverDirection.RecvOnly);
        break;
      }
    }

    _intendCam = false;
    camOn.value = false;
    _log('Camera stopped');
    await _renegotiate('stopCam');
  }

  Future<void> switchCamera() async {
    final v = _localStream?.getVideoTracks();
    if (v == null || v.isEmpty) return;
    await Helper.switchCamera(v.first);
    localRenderer.srcObject = _localStream; // ребинд
    _log('Camera switched');
    await _renegotiate('switchCamera');
  }

  void toggleMute() {
    final tracks = _localStream?.getAudioTracks();
    if (tracks == null || tracks.isEmpty) return;
    final nextMuted = !muted.value;
    for (final t in tracks) {
      t.enabled = !nextMuted;
    }
    muted.value = nextMuted;
    _log(nextMuted ? 'Mic muted' : 'Mic unmuted');
  }

  Future<void> hangUp() async {
    _sendWS({'type': 'bye', 'to': _remotePeerId});
    _log('Hangup requested');
    await _closePeer();
    roomId.value = null;
    connected.value = false;
    _remotePeerId = null;
  }

  Future<void> dumpSelectedIce() async {
    if (_pc == null) return;
    try {
      final stats = await _pc!.getStats();
      final byId = {for (final r in stats) r.id: r};

      for (final r in stats) {
        if (r.type == 'candidate-pair' &&
            ((r.values['selected'] == true) ||
             (r.values['state'] == 'succeeded'))) {
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

  // --------------------- сигналинг / SDP ---------------------

  Future<void> _ensureWS() async {
    if (_wsChan != null) return;
    _log('Connecting WS to $wsUrl …');
    _wsChan = WebSocketChannel.connect(Uri.parse(wsUrl));
    _wsChan!.stream.listen(_onWSMessage, onDone: () {
      _log('WS closed');
      _wsChan = null;
    }, onError: (e) {
      _log('WS error: $e');
      _wsChan = null;
    });
    _log('WS connected');
  }

  void _sendWS(Map<String, dynamic> m) {
    final id = roomId.value;
    if (id != null && !m.containsKey('roomId')) m['roomId'] = id;
    if (_remotePeerId != null && !m.containsKey('to')) m['to'] = _remotePeerId;
    _wsChan?.sink.add(jsonEncode(m));
  }

  Future<void> _onWSMessage(dynamic data) async {
    final text = data is String ? data : utf8.decode((data as List<int>));
    final msg = jsonDecode(text) as Map<String, dynamic>;
    final type = msg['type'] as String?;

    switch (type) {
      case 'created':
        roomId.value = msg['roomId'] as String?;
        _myPeerId = msg['peerId'] as String?;
        _log('Room confirmed by server: ${roomId.value}, myPeerId=$_myPeerId');
        break;

      case 'joined':
        roomId.value = msg['roomId'] as String?;
        _myPeerId = msg['peerId'] as String?;
        _log('Joined room ${roomId.value}, myPeerId=$_myPeerId');
        break;

      case 'peer-joined':
        _remotePeerId = msg['peerId'] as String?;
        _log('Peer joined: $_remotePeerId');

        // если у нас есть локальный OFFER — переотправим адресно новому пиру
        final desc = await _pc?.getLocalDescription();
        if (desc != null && desc.type == 'offer' && desc.sdp != null) {
          _sendWS({'type': 'offer', 'sdp': desc.sdp, 'to': _remotePeerId});
          _log('Re-send local OFFER to $_remotePeerId');
        }
        break;

      case 'offer':
        _remotePeerId = (msg['from'] ?? _remotePeerId) as String?;
        await _onRemoteOffer(msg['sdp'] as String);
        break;

      case 'answer':
        _remotePeerId = (msg['from'] ?? _remotePeerId) as String?;
        if (_pc == null) return;
        await _pc!.setRemoteDescription(
          RTCSessionDescription(msg['sdp'] as String, 'answer'),
        );
        _log('Remote ANSWER set (from: $_remotePeerId)');
        _remoteSet = true;

        for (final c in _pendingIce) {
          await _pc!.addCandidate(c);
        }
        _pendingIce.clear();

        Future.delayed(const Duration(seconds: 7), dumpSelectedIce);
        break;

      case 'ice':
        if (_pc == null) return;
        final obj = msg['candidate'];
        final ice = (obj is Map)
            ? RTCIceCandidate(
                obj['candidate'] as String?,
                obj['sdpMid'] as String?,
                (obj['sdpMLineIndex'] as num?)?.toInt(),
              )
            : RTCIceCandidate(
                msg['candidate'] as String?,
                msg['sdpMid'] as String?,
                (msg['sdpMLineIndex'] as num?)?.toInt(),
              );

        if (_remoteSet) {
          await _pc!.addCandidate(ice);
        } else {
          _pendingIce.add(ice);
        }
        _log('ICE << from:${msg['from']}  cached=${!_remoteSet}');
        break;

      case 'peer-left':
        final pid = msg['peerId'];
        _log('Peer left: $pid');
        if (_remotePeerId == pid) _remotePeerId = null;
        break;

      case 'bye':
        _log('Peer hung up');
        await _closePeer();
        roomId.value = null;
        _remotePeerId = null;
        break;

      default:
        _log('WS << $text');
    }
  }

  Future<void> _onRemoteOffer(String sdp) async {
    if (_pc == null) await _createPeer();

    await _pc!.setRemoteDescription(RTCSessionDescription(sdp, 'offer'));
    _log('Remote OFFER set (from: $_remotePeerId)');
    _remoteSet = true;

    // гарантируем наличие m-lines даже без локальных треков
    await _ensureRecvTransceivers();

    // подготовим локальные треки под ответ (если нужны)
    await _ensureLocalSendReady();

    for (final c in _pendingIce) {
      await _pc!.addCandidate(c);
    }
    _pendingIce.clear();

    if (_makingAnswer) {
      _log('Skip duplicate createAnswer()');
      return;
    }

    _makingAnswer = true;
    try {
      final answer = await _pc!.createAnswer({});
      await _pc!.setLocalDescription(answer);
      final local = await _pc!.getLocalDescription();
      _sendWS({'type': 'answer', 'sdp': local!.sdp, 'to': _remotePeerId});
      _log('ANSWER sent to $_remotePeerId');
    } catch (e) {
      _log('createAnswer failed: $e; retry with forced recvonly…');
      await _ensureRecvTransceivers(force: true);
      final retry = await _pc!.createAnswer({});
      await _pc!.setLocalDescription(retry);
      final local = await _pc!.getLocalDescription();
      _sendWS({'type': 'answer', 'sdp': local!.sdp, 'to': _remotePeerId});
      _log('ANSWER sent (retry) to $_remotePeerId');
    } finally {
      _makingAnswer = false;
    }

    Future.delayed(const Duration(seconds: 7), dumpSelectedIce);
  }

  Future<void> _createPeer() async {
    _pendingIce.clear();
    _remoteSet = false;

    // 1) ICE с твоего API
    _apiIce = await _fetchIceServers(userId);

    // 2) статический TURN из Env, если задан
    if (Env.turnHost.isNotEmpty) {
      _apiIce.add({
        'urls': 'turn:${Env.turnHost}:3478?transport=udp',
        'username': Env.turnUser,
        'credential': Env.turnPass,
      });
      _apiIce.add({
        'urls': 'turns:${Env.turnHost}:5349?transport=tcp',
        'username': Env.turnUser,
        'credential': Env.turnPass,
      });
    }

    final pc = await createPeerConnection(_buildRtcConfig(), {
      'mandatory': {},
      'optional': [
        {'DtlsSrtpKeyAgreement': true},
      ],
    });
    _pc = pc;

    // заранее создаём по одному транссиверу под A/V (Unified Plan)
    await pc.addTransceiver(
      kind: RTCRtpMediaType.RTCRtpMediaTypeAudio,
      init: RTCRtpTransceiverInit(direction: TransceiverDirection.SendRecv),
    );
    await pc.addTransceiver(
      kind: RTCRtpMediaType.RTCRtpMediaTypeVideo,
      init: RTCRtpTransceiverInit(direction: TransceiverDirection.SendRecv),
    );

    pc.onTrack = (RTCTrackEvent e) async {
      if (e.streams.isNotEmpty) {
        remoteRenderer.srcObject = e.streams.first;
      } else {
        remoteRenderer.srcObject ??= await createLocalMediaStream('remote');
        remoteRenderer.srcObject!.addTrack(e.track);
      }
      forceRebindRemote();
      _log('Remote track: ${e.track.kind}');
    };

    pc.onDataChannel = (dc) {
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
          },
          'to': _remotePeerId,
        });
        final preview = cand.candidate!;
        _log('ICE >> ${preview.length > 40 ? preview.substring(0, 40) : preview}… to=$_remotePeerId');
      }
    };

    pc.onSignalingState = (s) => _log('Signaling: $s');
    pc.onIceConnectionState = (s) {
      _log('ICE state: $s');
      connected.value =
          (s == RTCIceConnectionState.RTCIceConnectionStateConnected ||
           s == RTCIceConnectionState.RTCIceConnectionStateCompleted);
    };
    pc.onConnectionState = (s) => _log('PC state: $s');
  }

  Future<List<Map<String, dynamic>>> _fetchIceServers(String uid) async {
    final uri = Uri.parse('$apiBase/turn/credentials?user_id=$uid');
    try {
      final resp = await http.get(uri).timeout(const Duration(seconds: 7));
      if (resp.statusCode != 200) {
        _log('TURN creds error: ${resp.statusCode} ${resp.body}');
        return [];
      }
      final body = jsonDecode(resp.body) as Map<String, dynamic>;
      final list = (body['iceServers'] as List).cast<Map<String, dynamic>>();
      for (final s in list) {
        _log('ICE from API: ${s['urls']} user=${s['username'] ?? '-'}');
      }
      return list;
    } catch (e) {
      _log('TURN creds fetch failed: $e');
      return [];
    }
  }

  Map<String, dynamic> _buildRtcConfig() {
    // Нормализация: одна url на запись
    final norm = <Map<String, dynamic>>[];
    for (final s in [
      {'urls': 'stun:stun.l.google.com:19302'},
      ..._apiIce,
    ]) {
      final u = s['urls'];
      if (u is List) {
        for (final one in u) {
          norm.add({
            'urls': one,
            if (s['username'] != null) 'username': s['username'],
            if (s['credential'] != null) 'credential': s['credential'],
          });
        }
      } else {
        norm.add(s);
      }
    }

    return {
      'iceServers': norm,
      'sdpSemantics': 'unified-plan',
      'iceTransportPolicy': Env.forceRelay ? 'relay' : 'all',
      'bundlePolicy': 'max-bundle',
      'rtcpMuxPolicy': 'require',
      // 'iceCandidatePoolSize': 0, // можно включить при необходимости
    };
  }

  /// Готовим локальные треки под текущие намерения (_intendMic/_intendCam)
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

    // мобилам включаем громкую связь
    final isMobile = !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.android ||
         defaultTargetPlatform == TargetPlatform.iOS);
    if (isMobile) {
      await Helper.setSpeakerphoneOn(true);
    }
  }

  void _wireDataChannel() {
    _dc?.onMessage = (msg) {
      _chatIn.add(msg.text);
      _log('Peer: ${msg.text}');
    };
    _dc?.onDataChannelState = (state) => _log('DataChannel: $state');
  }

  Future<void> _makeOffer() async {
    final offer = await _pc!.createOffer({
      'offerToReceiveAudio': 1,
      'offerToReceiveVideo': 1,
    });
    await _pc!.setLocalDescription(offer);
    final local = await _pc!.getLocalDescription();
    _sendWS({'type': 'offer', 'sdp': local!.sdp, 'to': _remotePeerId});
    _log('OFFER sent via WS to=$_remotePeerId');
  }

  /// Гарантировать наличие recvonly-транссиверов под answer
  Future<void> _ensureRecvTransceivers({bool force = false}) async {
    if (_pc == null) return;

    final hasLocalA = _localStream?.getAudioTracks().isNotEmpty ?? false;
    final hasLocalV = _localStream?.getVideoTracks().isNotEmpty ?? false;
    if (!force && (hasLocalA || hasLocalV)) return;

    final txs = await _pc!.getTransceivers();

    bool hasAudio = txs.any((t) {
      final kind = t.receiver.track?.kind ?? t.sender.track?.kind;
      return kind == 'audio';
    });

    bool hasVideo = txs.any((t) {
      final kind = t.receiver.track?.kind ?? t.sender.track?.kind;
      return kind == 'video';
    });

    if (!hasAudio) {
      await _pc!.addTransceiver(
        kind: RTCRtpMediaType.RTCRtpMediaTypeAudio,
        init: RTCRtpTransceiverInit(direction: TransceiverDirection.RecvOnly),
      );
      _log('Transceiver audio recvonly added');
    }
    if (!hasVideo) {
      await _pc!.addTransceiver(
        kind: RTCRtpMediaType.RTCRtpMediaTypeVideo,
        init: RTCRtpTransceiverInit(direction: TransceiverDirection.RecvOnly),
      );
      _log('Transceiver video recvonly added');
    }
  }

  Future<void> _closePeer() async {
    try { await _dc?.close(); } catch (_) {}
    _dc = null;

    try { await _pc?.close(); } catch (_) {}
    _pc = null;

    // останавливаем и освобождаем локальные треки/стрим
    try {
      final tracks = [
        ...(_localStream?.getAudioTracks() ?? const []),
        ...(_localStream?.getVideoTracks() ?? const []),
      ];
      for (final t in tracks) {
        try { await t.stop(); } catch (_) {}
      }
    } catch (_) {}
    try { await _localStream?.dispose(); } catch (_) {}
    _localStream = null;

    _audioSender = null;
    _videoSender = null;
    _pendingIce.clear();
    _remoteSet = false;

    // очищаем рендереры
    localRenderer.srcObject = null;
    remoteRenderer.srcObject = null;

    micOn.value = false;
    camOn.value = false;
    muted.value = false;
  }

  Future<void> _renegotiate(String reason) async {
    if (_pc == null) return;
    if (_negotiationInFlight) {
      _log('Renegotiate skipped ($reason): in-flight');
      return;
    }
    _negotiationInFlight = true;
    try {
      _log('Renegotiate: $reason');
      final offer = await _pc!.createOffer({});
      await _pc!.setLocalDescription(offer);
      final local = await _pc!.getLocalDescription();
      _sendWS({'type': 'offer', 'sdp': local!.sdp, 'to': _remotePeerId});
      _log('OFFER (renegotiate) sent to=$_remotePeerId');
    } catch (e) {
      _log('Renegotiate error: $e');
    } finally {
      _negotiationInFlight = false;
    }
  }

  // --------------------- утиль ---------------------

  String _genRoomId() {
    final rnd = Random();
    return rnd.nextInt(0x7FFFFFFF).toRadixString(16).padLeft(8, '0');
    // можно заменить на любой другой генератор
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

  void forceRebindLocal() {
    if (_localStream != null) {
      localRenderer.srcObject = _localStream;
    }
  }

  void forceRebindRemote() {
    if (remoteRenderer.srcObject != null) {
      remoteRenderer.srcObject = remoteRenderer.srcObject; // «пинок» рендереру
    }
  }
}
