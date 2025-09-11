import 'dart:math';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_web_plugins/url_strategy.dart' show setUrlStrategy, PathUrlStrategy;

import 'config/env.dart';
import 'backend/rtc_engine.dart';
import 'frontend/call_page.dart';

String? _parseInitialRoomIdFromUrl() {
  if (!kIsWeb) return null;
  final uri = Uri.base;

  // Поддерживаем /j/<id> и /r/<id>
  if (uri.pathSegments.length >= 2 &&
      (uri.pathSegments.first == 'j' || uri.pathSegments.first == 'r')) {
    return uri.pathSegments[1];
  }

  // Фолбэк: ?room=<id>
  return uri.queryParameters['room'];
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  if (kIsWeb) {
    setUrlStrategy(PathUrlStrategy()); // убираем #/
  }
  runApp(const WunderApp());
}

class WunderApp extends StatefulWidget {
  const WunderApp({super.key});

  @override
  State<WunderApp> createState() => _WunderAppState();
}

class _WunderAppState extends State<WunderApp> {
  late final WebRTCEngine _engine = WebRTCEngine(
    wsUrl: Env.wsUrl,
    apiBase: Env.apiBase,
    userId: 'client-${DateTime.now().millisecondsSinceEpoch}-${Random().nextInt(9999)}',
  );

  late final String? _initialRoomId = _parseInitialRoomIdFromUrl();

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Wunder WebRTC',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.teal),
      home: CallPage(
        engine: _engine,
        initialRoomId: _initialRoomId,
        // авто-join включён; камера по умолчанию off — гость может включить в UI
        autoJoinOnStartup: true,
      ),
    );
  }
}
