import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

class AudioCalleePage extends StatefulWidget {
  const AudioCalleePage({super.key});
  @override
  State<AudioCalleePage> createState() => _AudioCalleePageState();
}

class _AudioCalleePageState extends State<AudioCalleePage> {
  RTCPeerConnection? pc;
  final remoteRenderer = RTCVideoRenderer(); // для аудио тоже норм
  final offerCtrl = TextEditingController(); // сюда вставляем offer.sdp
  final candidateCtrl = TextEditingController(); // сюда вставляем по одному ICE-кандидату (JSON)
  String localAnswerSdp = '';
  final _myCandidates = <RTCIceCandidate>[];

  @override
  void initState() {
    super.initState();
    remoteRenderer.initialize();
    _initPc();
  }

  Future<void> _initPc() async {
    // Без STUN/TURN — подойдут только "host" кандидаты (одна сеть). Для реальных сетей добавьте STUN/TURN.
    final config = {
      'iceServers': <Map<String, dynamic>>[], // позже добавите STUN/TURN
      // 'iceTransportPolicy': 'all', // по умолчанию
    };

    pc = await createPeerConnection(config);

    // Мы принимающая сторона: явно объявим, что хотим только принимать аудио
    await pc!.addTransceiver(
      kind: RTCRtpMediaType.RTCRtpMediaTypeAudio,
      init: RTCRtpTransceiverInit(
        direction: TransceiverDirection.RecvOnly,
      ),
    );

    // Входящие дорожки (удалённый звук)
    pc!.onTrack = (RTCTrackEvent e) {
      if (e.streams.isNotEmpty) {
        remoteRenderer.srcObject = e.streams.first;
      }
    };

    // Наши ICE-кандидаты — печатаем, чтобы вы могли скопировать и переслать звонящему
    pc!.onIceCandidate = (c) {
      if (c.candidate != null) {
        _myCandidates.add(c);
        debugPrint('MY_CANDIDATE_JSON: ${jsonEncode({
          'candidate': c.candidate,
          'sdpMid': c.sdpMid,
          'sdpMLineIndex': c.sdpMLineIndex,
        })}');
      }
    };
  }

  Future<void> _applyRemoteOfferAndCreateAnswer() async {
    final sdp = offerCtrl.text.trim();
    if (sdp.isEmpty || pc == null) return;

    await pc!.setRemoteDescription(
      RTCSessionDescription(sdp, 'offer'),
    );

    // Создаём answer без локального микрофона — мы только слушаем
    final answer = await pc!.createAnswer({
      'offerToReceiveAudio': 1, // на всякий случай
      'offerToReceiveVideo': 0,
    });
    await pc!.setLocalDescription(answer);

    setState(() {
      localAnswerSdp = answer.sdp ?? '';
    });
  }

  Future<void> _addRemoteCandidateFromText() async {
    final raw = candidateCtrl.text.trim();
    if (raw.isEmpty || pc == null) return;

    // Ожидаем формата:
    // {"candidate":"candidate:...","sdpMid":"audio","sdpMLineIndex":0}
    final map = jsonDecode(raw) as Map<String, dynamic>;
    final cand = RTCIceCandidate(
      map['candidate'] as String?,
      map['sdpMid'] as String?,
      map['sdpMLineIndex'] as int?,
    );
    await pc!.addCandidate(cand);
    candidateCtrl.clear();
  }

  @override
  void dispose() {
    remoteRenderer.dispose();
    offerCtrl.dispose();
    candidateCtrl.dispose();
    pc?.close();
    pc?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('WebRTC Callee (Audio Only)')),
      body: Padding(
        padding: const EdgeInsets.all(12),
        child: ListView(
          children: [
            const Text('1) Вставь сюда OFFER SDP от звонящего:'),
            TextField(
              controller: offerCtrl,
              maxLines: 8,
              decoration: const InputDecoration(border: OutlineInputBorder()),
            ),
            const SizedBox(height: 8),
            ElevatedButton(
              onPressed: _applyRemoteOfferAndCreateAnswer,
              child: const Text('Принять offer и создать answer'),
            ),
            const SizedBox(height: 12),
            const Text('2) Скопируй этот ANSWER SDP и отправь звонящему:'),
            SelectableText(
              localAnswerSdp.isEmpty ? '(пока пусто)' : localAnswerSdp,
            ),
            const SizedBox(height: 12),
            const Text('3) Твои ICE-кандидаты (смотри в логи; копируй по одному звонящему)'),
            const SizedBox(height: 8),
            const Text('4) Вставляй сюда ICE-кандидаты звонящего (JSON) и жми добавить:'),
            TextField(
              controller: candidateCtrl,
              maxLines: 5,
              decoration: const InputDecoration(
                hintText: '{"candidate":"...","sdpMid":"audio","sdpMLineIndex":0}',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            ElevatedButton(
              onPressed: _addRemoteCandidateFromText,
              child: const Text('Добавить кандидат'),
            ),
            const Divider(height: 24),
            const Text('Воспроизведение (аудио без видео):'),
            // Для аудио renderer не обязателен, но так проще держать ссылку на поток
            SizedBox(
              height: 0, // не показываем видео, звук будет играть
              child: RTCVideoView(remoteRenderer, objectFit: RTCVideoViewObjectFit.RTCVideoViewObjectFitContain),
            ),
          ],
        ),
      ),
    );
  }
}
