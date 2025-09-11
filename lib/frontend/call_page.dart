import 'package:flutter/material.dart';
import '../backend/rtc_engine.dart';
import 'widgets/lobby.dart';
import 'widgets/video_stage.dart';

class CallPage extends StatefulWidget {
  const CallPage({
    super.key,
    required this.engine,
    this.initialRoomId,
    this.autoJoinOnStartup = true, // авто-join по диплинку
  });

  final WebRTCEngine engine;
  final String? initialRoomId;
  final bool autoJoinOnStartup;

  @override
  State<CallPage> createState() => _CallPageState();
}

class _CallPageState extends State<CallPage> {
  final _roomCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _init(); // делаем корректную async-инициализацию
  }

  Future<void> _init() async {
    // Важно: инициализируем рендереры ДО любых join/offer
    await widget.engine.init();

    // автоподключение только если явно разрешено и есть валидный roomId
    final rid = widget.initialRoomId;
    if (widget.autoJoinOnStartup && rid != null && rid.isNotEmpty) {
      _roomCtrl.text = rid; // чтобы показывалось в Lobby при возврате
      // По умолчанию: микрофон ON, камера OFF (пользователь включит из UI).
      // При включении камеры у гостя пойдёт ренегоциация — у хоста появится видео.
      await widget.engine.joinRoom(rid, withMic: true, withCam: false);
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
