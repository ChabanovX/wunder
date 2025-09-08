import 'package:flutter/material.dart';
import '../backend/rtc_engine.dart';
import 'widgets/lobby.dart';
import 'widgets/video_stage.dart';

class CallPage extends StatefulWidget {
  const CallPage({
    super.key,
    required this.engine,
    this.initialRoomId, // <- новый параметр
  });

  final WebRTCEngine engine;
  final String? initialRoomId;

  @override
  State<CallPage> createState() => _CallPageState();
}

class _CallPageState extends State<CallPage> {
  final _roomCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    widget.engine.init();

    // если пришли по ссылке /r/<roomId> — сразу подключаемся
    final rid = widget.initialRoomId;
    if (rid != null && rid.isNotEmpty) {
      _roomCtrl.text = rid; // чтобы показывалось в Lobby при возврате
      // по умолчанию подключаемся с микрофоном, без камеры (можешь поменять)
      widget.engine.joinRoom(rid, withMic: true, withCam: false);
    }
  }

  @override
  void dispose() {
    _roomCtrl.dispose();
    widget.engine.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final e = widget.engine;

    return Scaffold(
      extendBody: true, // панель снизу поверх видео
      appBar: AppBar(title: const Text('Wunder Calls'), centerTitle: true),
      body: SizedBox.expand(
        child: ValueListenableBuilder<String?>(
          valueListenable: e.roomId,
          builder: (_, room, __) {
            if (room == null || room.isEmpty) {
              return Lobby(engine: e, roomCtrl: _roomCtrl);
            }
            return VideoStage(engine: e, roomId: room);
          },
        ),
      ),
    );
  }
}
