import 'package:flutter/material.dart';

// относительные импорты из lib/
import 'backend/rtc_engine.dart';
import 'frontend/call_page.dart';



void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const WunderApp());
}

class WunderApp extends StatelessWidget {
  const WunderApp({super.key});

  @override
  Widget build(BuildContext context) {
    final engine = WebRTCEngine(
      wsUrl: 'ws://208.123.185.205:8080',
      apiBase: 'http://208.123.185.205:8000',
      userId: 'demo-device',
    );

    return MaterialApp(
      title: 'Wunder WebRTC',
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.teal),
      home: CallPage(engine: engine),
    );
  }
}
