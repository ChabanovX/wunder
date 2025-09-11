// lib/frontend/utils/deeplink.dart
import '../../config/env.dart';

String _trimSlashes(String s) => s.replaceAll(RegExp(r'/+$'), '');

/// Каноничный диплинк для приглашения в комнату.
String buildJoinUrl(String roomId) {
  final base = _trimSlashes(Env.appOrigin);
  return '$base/j/$roomId';
}

/// Парсинг roomId из текущего URL (web SPA).
/// Поддерживает /j/<id> и ?room=<id>.
String? roomIdFromCurrentUrl() {
  final uri = Uri.base;
  if (uri.pathSegments.length >= 2 && uri.pathSegments.first == 'j') {
    return uri.pathSegments[1];
  }
  return uri.queryParameters['room'];
}
