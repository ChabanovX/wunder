// lib/main.dart
import 'dart:math';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

// только этот импорт нужен для чистых URL
import 'package:flutter_web_plugins/url_strategy.dart'
    show setUrlStrategy, PathUrlStrategy;

import 'config/env.dart';
import 'backend/rtc_engine.dart';
import 'frontend/call_page.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  // На web убираем `#/` из адресной строки (Vercel/Nginx ок)
  if (kIsWeb) {
    setUrlStrategy(PathUrlStrategy()); // <-- без const
  }

  runApp(const WunderApp());
}

class WunderApp extends StatelessWidget {
  const WunderApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Wunder WebRTC',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.teal),
      onGenerateRoute: (settings) {
        // deeplink: /r/<roomId> для веба
        String? initialRoomId;
        if (kIsWeb) {
          final segs = Uri.base.pathSegments;
          if (segs.isNotEmpty && segs.first == 'r' && segs.length >= 2) {
            initialRoomId = segs[1].replaceAll('/', '');
          }
        }

        final engine = WebRTCEngine(
          wsUrl: Env.wsUrl,
          apiBase: Env.apiBase,
          userId:
              'client-${DateTime.now().millisecondsSinceEpoch}-${Random().nextInt(9999)}',
        );

        return MaterialPageRoute(
          builder: (_) => CallPage(
            engine: engine,
            initialRoomId: initialRoomId,
          ),
        );
      },
    );
  }
}
