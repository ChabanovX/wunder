// lib/config/env.dart
class Env {
  // WebSocket сигналинг (например: wss://signal.wundercalls.ru/ws)
  static const wsUrl = String.fromEnvironment(
    'WS_URL',
    defaultValue: 'ws://localhost:8080/ws',
  );

  // REST API (например: https://api.wundercalls.ru)
  static const apiBase = String.fromEnvironment(
    'API_BASE',
    defaultValue: 'http://localhost:8000',
  );

  // TURN (fallback для сложных NAT)
  static const turnHost = String.fromEnvironment('TURN_HOST', defaultValue: '');
  static const turnUser = String.fromEnvironment('TURN_USER', defaultValue: '');
  static const turnPass = String.fromEnvironment('TURN_PASS', defaultValue: '');

  // Диагностика: строить связь только через TURN
  static const forceRelay = bool.fromEnvironment('FORCE_RELAY', defaultValue: false);

  // Публичный origin веб-клиента (для формирования диплинков)
  // Пример прод: https://app.wundercalls.ru
  static const appOrigin = String.fromEnvironment(
    'APP_ORIGIN',
    defaultValue: 'http://localhost:5500', // подставь свой dev-origin
  );
}
