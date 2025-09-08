import 'package:web_socket_channel/html.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'ws_base.dart';

class WsWeb implements WsClient {
  final WebSocketChannel _ch;
  WsWeb(this._ch);

  @override
  Stream get stream => _ch.stream;

  @override
  void send(String data) => _ch.sink.add(data);

  @override
  Future<void> close([int? code, String? reason]) async => _ch.sink.close(code, reason);
}

Future<WsClient> createWs(String url) async => WsWeb(HtmlWebSocketChannel.connect(url));
