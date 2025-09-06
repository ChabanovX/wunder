import 'dart:async';
import 'package:flutter/material.dart';

import '../../backend/rtc_engine.dart';

class ChatLogsSheet extends StatefulWidget {
  const ChatLogsSheet({super.key, required this.engine});
  final WebRTCEngine engine;

  @override
  State<ChatLogsSheet> createState() => _ChatLogsSheetState();
}

class _ChatLogsSheetState extends State<ChatLogsSheet>
    with SingleTickerProviderStateMixin {
  final _chatCtrl = TextEditingController();
  late final TabController _tabs;
  final _messages = <String>[];
  StreamSubscription<String>? _sub;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 2, vsync: this);
    _sub = widget.engine.chatStream.listen((m) {
      setState(() => _messages.add('Peer: $m'));
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    _chatCtrl.dispose();
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final e = widget.engine;

    return DraggableScrollableSheet(
      expand: false,
      minChildSize: 0.35,
      maxChildSize: 0.92,
      initialChildSize: 0.60,
      builder: (context, scrollCtrl) {
        return Container(
          clipBehavior: Clip.hardEdge,
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
          ),
          child: Column(
            children: [
              // header
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.grey.shade100,
                  border: Border(bottom: BorderSide(color: Colors.grey.shade300)),
                ),
                child: Row(
                  children: [
                    const Text('Chat & Logs', style: TextStyle(fontWeight: FontWeight.w600)),
                    const Spacer(),
                    IconButton(
                      icon: const Icon(Icons.close),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ],
                ),
              ),

              // tabs
              TabBar(
                controller: _tabs,
                labelColor: Colors.black87,
                tabs: const [
                  Tab(icon: Icon(Icons.chat_bubble_outline), text: 'Chat'),
                  Tab(icon: Icon(Icons.receipt_long_outlined), text: 'Logs'),
                ],
              ),

              Expanded(
                child: TabBarView(
                  controller: _tabs,
                  children: [
                    // --- CHAT ---
                    Column(
                      children: [
                        Expanded(
                          child: ListView.builder(
                            controller: scrollCtrl,
                            padding: const EdgeInsets.all(12),
                            itemCount: _messages.length,
                            itemBuilder: (_, i) => Padding(
                              padding: const EdgeInsets.symmetric(vertical: 4),
                              child: Align(
                                alignment: _messages[i].startsWith('Me:')
                                    ? Alignment.centerRight
                                    : Alignment.centerLeft,
                                child: DecoratedBox(
                                  decoration: BoxDecoration(
                                    color: _messages[i].startsWith('Me:')
                                        ? Colors.teal.shade50
                                        : Colors.grey.shade100,
                                    borderRadius: BorderRadius.circular(10),
                                  ),
                                  child: Padding(
                                    padding: const EdgeInsets.all(10),
                                    child: Text(_messages[i]),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                          child: Row(
                            children: [
                              Expanded(
                                child: TextField(
                                  controller: _chatCtrl,
                                  decoration: const InputDecoration(
                                    hintText: 'Type message…',
                                    border: OutlineInputBorder(),
                                    isDense: true,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              FilledButton(
                                onPressed: () {
                                  final txt = _chatCtrl.text.trim();
                                  if (txt.isEmpty) return;
                                  e.sendChat(txt);
                                  setState(() => _messages.add('Me: $txt'));
                                  _chatCtrl.clear();
                                },
                                child: const Text('Send'),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),

                    // --- LOGS ---
                    Padding(
                      padding: const EdgeInsets.all(12),
                      child: ValueListenableBuilder<List<String>>(
                        valueListenable: e.logs,
                        builder: (_, list, __) => SingleChildScrollView(
                          controller: scrollCtrl,
                          child: SelectableText(list.join('\n')),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
