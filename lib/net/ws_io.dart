import 'dart:io';
import 'ws_base.dart';

class WsIo implements WsClient {
  final WebSocket _ws;
  WsIo(this._ws);

  @override
  Stream get stream => _ws;

  @override
  void send(String data) => _ws.add(data);

  @override
  Future<void> close([int? code, String? reason]) => _ws.close(code, reason);
}

Future<WsClient> createWs(String url) async => WsIo(await WebSocket.connect(url));
