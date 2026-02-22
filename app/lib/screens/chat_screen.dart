import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import '../theme.dart';

const _baseUrl = 'http://127.0.0.1:8179';

class ChatMessage {
  final String role; // 'user' or 'assistant'
  final String content;
  ChatMessage({required this.role, required this.content});
  Map<String, String> toJson() => {'role': role, 'content': content};
}

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});
  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _controller = TextEditingController();
  final _scrollController = ScrollController();
  final _focusNode = FocusNode();
  final List<ChatMessage> _messages = [];
  bool _loading = false;
  bool _llmAvailable = false;
  bool _llmLoaded = false;
  bool _downloading = false;
  String _streamBuffer = '';

  @override
  void initState() {
    super.initState();
    _checkLlmStatus().then((_) => _maybeAutoDownload());
  }

  @override
  void dispose() {
    _controller.dispose();
    _scrollController.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  // ── HTTP helpers ──

  Future<Map<String, dynamic>?> _get(String path) async {
    try {
      final c = HttpClient()..connectionTimeout = const Duration(seconds: 2);
      final req = await c.getUrl(Uri.parse('$_baseUrl$path'));
      final resp = await req.close().timeout(const Duration(seconds: 3));
      final data = await resp.transform(utf8.decoder).join();
      c.close();
      return jsonDecode(data) as Map<String, dynamic>;
    } catch (_) { return null; }
  }

  Future<void> _checkLlmStatus() async {
    final status = await _get('/llm/status');
    if (mounted && status != null) {
      setState(() {
        _llmAvailable = status['available'] as bool? ?? false;
        _llmLoaded = status['loaded'] as bool? ?? false;
      });
    }
  }

  Future<void> _maybeAutoDownload() async {
    if (_llmAvailable || _llmLoaded || _downloading) return;
    // Small delay so the screen renders first
    await Future.delayed(const Duration(milliseconds: 500));
    if (!mounted || _llmAvailable || _llmLoaded) return;

    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: C.level2,
        title: const Text('Download AI Model?',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: C.text)),
        content: const Text(
          'Qwen3-1.7B (Q4_K_M) — ~1.1 GB\nRuns 100% offline on your GPU.\n\nDownload now?',
          style: TextStyle(fontSize: 13, color: C.textSub, height: 1.5)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Later', style: TextStyle(color: C.textMuted))),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Download', style: TextStyle(color: C.accent))),
        ],
      ),
    );
    if (confirm == true && mounted) {
      _downloadModel();
    }
  }

  Future<void> _downloadModel() async {
    setState(() => _downloading = true);
    try {
      final c = HttpClient()..connectionTimeout = const Duration(seconds: 5);
      final req = await c.postUrl(Uri.parse('$_baseUrl/llm/download'));
      req.headers.set('Content-Type', 'application/json');
      req.write('{}');
      final resp = await req.close().timeout(const Duration(minutes: 10));
      final data = await resp.transform(utf8.decoder).join();
      c.close();
      final result = jsonDecode(data) as Map<String, dynamic>;
      if (result['ok'] == true) {
        // Poll until model is loaded (auto-load happens in sidecar)
        for (var i = 0; i < 30; i++) {
          await Future.delayed(const Duration(seconds: 2));
          await _checkLlmStatus();
          if (_llmLoaded) break;
        }
      }
    } catch (e) {
      // ignore
    } finally {
      if (mounted) setState(() => _downloading = false);
    }
  }

  // ── Chat with SSE streaming ──

  Future<void> _sendMessage() async {
    final text = _controller.text.trim();
    if (text.isEmpty || _loading) return;

    _controller.clear();
    setState(() {
      _messages.add(ChatMessage(role: 'user', content: text));
      _loading = true;
      _streamBuffer = '';
    });
    _scrollToBottom();

    // Build history (last 10 messages for context)
    final history = _messages
        .where((m) => m != _messages.last)
        .toList()
        .reversed
        .take(10)
        .toList()
        .reversed
        .map((m) => m.toJson())
        .toList();

    try {
      final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
      final req = await client.postUrl(Uri.parse('$_baseUrl/chat'));
      req.headers.set('Content-Type', 'application/json; charset=utf-8');
      req.add(utf8.encode(jsonEncode({
        'message': text,
        'history': history,
        'stream': true,
      })));
      final resp = await req.close().timeout(const Duration(minutes: 2));

      // Add placeholder for assistant response
      setState(() {
        _messages.add(ChatMessage(role: 'assistant', content: ''));
      });

      await for (final chunk in resp.transform(utf8.decoder)) {
        for (final line in chunk.split('\n')) {
          if (!line.startsWith('data: ')) continue;
          final payload = line.substring(6).trim();
          if (payload == '[DONE]') break;
          try {
            final data = jsonDecode(payload) as Map<String, dynamic>;
            if (data.containsKey('token')) {
              _streamBuffer += data['token'] as String;
              if (mounted) {
                setState(() {
                  _messages.last = ChatMessage(
                    role: 'assistant',
                    content: _streamBuffer,
                  );
                });
                _scrollToBottom();
              }
            }
          } catch (_) {}
        }
      }
      client.close();
    } catch (e) {
      if (mounted) {
        setState(() {
          _messages.add(ChatMessage(
            role: 'assistant',
            content: 'Error: $e',
          ));
        });
      }
    } finally {
      if (mounted) {
        setState(() => _loading = false);
        _focusNode.requestFocus();
      }
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _clearChat() {
    setState(() {
      _messages.clear();
      _streamBuffer = '';
    });
  }

  // ── Build ──

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      _header(),
      Expanded(
        child: !_llmAvailable && !_llmLoaded
            ? _downloadView()
            : _chatView(),
      ),
      if (_llmAvailable || _llmLoaded) _inputBar(),
    ]);
  }

  Widget _header() {
    return Container(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 12),
      child: Row(children: [
        const Text('Chat', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700,
          color: C.text, letterSpacing: -0.5)),
        const SizedBox(width: 12),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: (_llmLoaded ? C.success : C.textMuted).withAlpha(20),
            borderRadius: BorderRadius.circular(6)),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Container(width: 6, height: 6, decoration: BoxDecoration(shape: BoxShape.circle,
              color: _llmLoaded ? C.success : (_llmAvailable ? C.warning : C.textMuted))),
            const SizedBox(width: 6),
            Text(
              _llmLoaded ? 'Qwen3-1.7B' : (_llmAvailable ? 'Loading...' : 'No model'),
              style: TextStyle(fontSize: 11,
                color: _llmLoaded ? C.success : C.textMuted,
                fontWeight: FontWeight.w500)),
          ]),
        ),
        const Spacer(),
        if (_messages.isNotEmpty)
          GestureDetector(
            onTap: _clearChat,
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(color: C.level2, borderRadius: BorderRadius.circular(6)),
                child: const Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.delete_outline_rounded, size: 14, color: C.textMuted),
                  SizedBox(width: 4),
                  Text('Clear', style: TextStyle(fontSize: 11, color: C.textMuted)),
                ]),
              ),
            ),
          ),
      ]),
    );
  }

  Widget _downloadView() {
    return Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
      Icon(Icons.smart_toy_outlined, size: 48, color: C.textMuted.withAlpha(80)),
      const SizedBox(height: 16),
      const Text('Local AI Chat', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: C.text)),
      const SizedBox(height: 8),
      const Text('Powered by Qwen3-1.7B — runs 100% offline',
        style: TextStyle(fontSize: 12, color: C.textSub)),
      const SizedBox(height: 6),
      const Text('~1.1 GB download', style: TextStyle(fontSize: 11, color: C.textMuted)),
      const SizedBox(height: 24),
      GestureDetector(
        onTap: _downloading ? null : _downloadModel,
        child: MouseRegion(
          cursor: _downloading ? SystemMouseCursors.basic : SystemMouseCursors.click,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
            decoration: BoxDecoration(
              color: _downloading ? C.level2 : C.accent,
              borderRadius: BorderRadius.circular(8)),
            child: _downloading
              ? const Row(mainAxisSize: MainAxisSize.min, children: [
                  SizedBox(width: 14, height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2, color: C.textSub)),
                  SizedBox(width: 8),
                  Text('Downloading...', style: TextStyle(fontSize: 13, color: C.textSub)),
                ])
              : const Text('Download Model',
                  style: TextStyle(fontSize: 13, color: Colors.white, fontWeight: FontWeight.w600)),
          ),
        ),
      ),
    ]));
  }

  Widget _chatView() {
    if (_messages.isEmpty) {
      return Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.chat_bubble_outline_rounded, size: 40, color: C.textMuted.withAlpha(60)),
        const SizedBox(height: 12),
        const Text('Start a conversation', style: TextStyle(fontSize: 14, color: C.textMuted)),
        const SizedBox(height: 4),
        const Text('100% local, 100% private', style: TextStyle(fontSize: 11, color: C.textMuted)),
      ]));
    }

    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
      itemCount: _messages.length,
      itemBuilder: (_, i) => _messageBubble(_messages[i]),
    );
  }

  Widget _messageBubble(ChatMessage msg) {
    final isUser = msg.role == 'user';
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        mainAxisAlignment: isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!isUser) ...[
            Container(
              width: 28, height: 28,
              decoration: BoxDecoration(
                color: C.accent.withAlpha(20), borderRadius: BorderRadius.circular(8)),
              child: const Icon(Icons.smart_toy_outlined, size: 16, color: C.accent),
            ),
            const SizedBox(width: 8),
          ],
          Flexible(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: isUser ? C.accent.withAlpha(20) : C.level2,
                borderRadius: BorderRadius.circular(12)),
              child: SelectableText(
                msg.content.isEmpty && _loading ? '...' : msg.content,
                style: TextStyle(
                  fontSize: 13, color: C.text, height: 1.5,
                  fontStyle: msg.content.isEmpty && _loading ? FontStyle.italic : FontStyle.normal,
                ),
              ),
            ),
          ),
          if (isUser) const SizedBox(width: 8),
        ],
      ),
    );
  }

  Widget _inputBar() {
    return Container(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
      child: Row(children: [
        Expanded(
          child: Container(
            decoration: BoxDecoration(color: C.level2, borderRadius: BorderRadius.circular(10)),
            child: TextField(
              controller: _controller,
              focusNode: _focusNode,
              autofocus: true,
              style: const TextStyle(fontSize: 13, color: C.text),
              decoration: InputDecoration(
                hintText: _loading ? 'Thinking...' : 'Type a message...',
                hintStyle: const TextStyle(fontSize: 13, color: C.textMuted),
                border: InputBorder.none,
                contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              ),
              onSubmitted: (_) => _sendMessage(),
              enabled: !_loading,
            ),
          ),
        ),
        const SizedBox(width: 8),
        GestureDetector(
          onTap: _loading ? null : _sendMessage,
          child: MouseRegion(
            cursor: _loading ? SystemMouseCursors.basic : SystemMouseCursors.click,
            child: Container(
              width: 40, height: 40,
              decoration: BoxDecoration(
                color: _loading ? C.level2 : C.accent,
                borderRadius: BorderRadius.circular(10)),
              child: Icon(
                _loading ? Icons.hourglass_top_rounded : Icons.send_rounded,
                size: 18, color: _loading ? C.textMuted : Colors.white),
            ),
          ),
        ),
      ]),
    );
  }
}
