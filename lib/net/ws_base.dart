// Базовый интерфейс клиента WebSocket (используется в web-реализации)
abstract class WsClient {
  Stream<dynamic> get stream;
  void send(String data);
  Future<void> close([int? code, String? reason]);
}
