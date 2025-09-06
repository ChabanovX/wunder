import 'package:flutter/material.dart';
import '../backend/rtc_engine.dart';
import 'widgets/lobby.dart';
import 'widgets/video_stage.dart';

class CallPage extends StatefulWidget {
  const CallPage({super.key, required this.engine});
  final WebRTCEngine engine;

  @override
  State<CallPage> createState() => _CallPageState();
}

class _CallPageState extends State<CallPage> {
  final _roomCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    widget.engine.init();
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
      body: SizedBox.expand( // гарантированно занимаем весь экран под AppBar
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
