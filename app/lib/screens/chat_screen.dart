import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import '../theme.dart';
import '../main.dart';
import '../voice_names.dart';
import '../src/rust/api/engine.dart';
const _baseUrl = 'http://127.0.0.1:8179';

class ChatMessage {
  final String role; // 'user' or 'assistant'
  final String content;
  ChatMessage({required this.role, required this.content});
  Map<String, String> toJson() => {'role': role, 'content': content};
}

class _ChatModel {
  final String id;
  final String label;
  final String description;
  final bool available;
  final bool supportsThinking;
  final bool cloud;
  _ChatModel({required this.id, required this.label, required this.description,
    required this.available, required this.supportsThinking, required this.cloud});
}

class ChatScreen extends StatefulWidget {
  final VoidCallback? onEnter;
  final VoidCallback? onLeave;
  final AppSettings settings;
  const ChatScreen({super.key, this.onEnter, this.onLeave, required this.settings});
  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _controller = TextEditingController();
  final _scrollController = ScrollController();
  final _focusNode = FocusNode();
  final List<ChatMessage> _messages = [];
  bool _loading = false;
  String _streamBuffer = '';

  // Model selection
  List<_ChatModel> _models = [];
  String _selectedModel = '';
  bool _groqAvailable = false;

  // Voice chat state
  bool _voiceMode = false;
  String _voiceState = 'stopped';
  WebSocket? _voiceWs;
  bool _ttsAvailable = false;

  // Voice selector
  List<FfiVoiceInfo> _builtinVoices = [];

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    await _fetchModels();
    await _checkVoiceChatStatus();
    _loadVoices();
  }

  void _loadVoices() async {
    final voices = await listBuiltinVoices();
    if (mounted) setState(() => _builtinVoices = voices);
  }

  @override
  void dispose() {
    _stopVoiceChat();
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

  Future<void> _fetchModels() async {
    final data = await _get('/chat/models');
    if (data != null && mounted) {
      final list = (data['models'] as List?)?.map((m) {
        final map = m as Map<String, dynamic>;
        return _ChatModel(
          id: map['id'] as String? ?? '',
          label: map['label'] as String? ?? '',
          description: map['description'] as String? ?? '',
          available: map['available'] as bool? ?? false,
          supportsThinking: map['supports_thinking'] as bool? ?? false,
          cloud: map['cloud'] as bool? ?? false,
        );
      }).toList() ?? [];
      setState(() {
        _models = list;
        _groqAvailable = data['groq_available'] as bool? ?? false;
        // Default to first available Groq model
        if (_selectedModel.isEmpty && list.any((m) => m.available)) {
          _selectedModel = list.firstWhere((m) => m.available).id;
        }
      });
    }
  }

  bool get _modelReady => _groqAvailable;

  _ChatModel? get _currentModel {
    try { return _models.firstWhere((m) => m.id == _selectedModel); }
    catch (_) { return null; }
  }

  Future<void> _checkVoiceChatStatus() async {
    final vcStatus = await _get('/voice-chat/status');
    if (mounted) {
      setState(() {
        if (vcStatus != null) {
          _ttsAvailable = vcStatus['tts_available'] as bool? ?? false;
        }
      });
    }
  }

  void _onModelChanged(String modelId) {
    if (modelId == _selectedModel) return;
    setState(() => _selectedModel = modelId);
  }

  // ── Voice Chat ──

  Future<void> _toggleVoiceMode() async {
    if (_voiceMode) { _stopVoiceChat(); } else { await _startVoiceChat(); }
  }

  Future<void> _startVoiceChat() async {
    try {
      _voiceWs = await WebSocket.connect('ws://127.0.0.1:8179/voice-chat')
          .timeout(const Duration(seconds: 3));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Voice chat connection failed: $e'),
            backgroundColor: C.error));
      }
      return;
    }
    setState(() { _voiceMode = true; _voiceState = 'connecting'; });
    _voiceWs!.add(jsonEncode({'action': 'start', 'model': _selectedModel}));
    _voiceWs!.listen(
      (data) {
        if (!mounted) return;
        try {
          final event = jsonDecode(data as String) as Map<String, dynamic>;
          _handleVoiceEvent(event);
        } catch (_) {}
      },
      onDone: () { if (mounted) setState(() { _voiceMode = false; _voiceState = 'stopped'; }); },
      onError: (_) { if (mounted) setState(() { _voiceMode = false; _voiceState = 'stopped'; }); },
    );
  }

  void _handleVoiceEvent(Map<String, dynamic> event) {
    final type = event['type'] as String? ?? '';
    switch (type) {
      case 'state':
        setState(() => _voiceState = event['state'] as String? ?? 'stopped');
        if (_voiceState == 'stopped') setState(() => _voiceMode = false);
        break;
      case 'user_text':
        final text = event['text'] as String? ?? '';
        setState(() => _messages.add(ChatMessage(role: 'user', content: text)));
        _scrollToBottom();
        break;
      case 'assistant_text':
        final text = event['text'] as String? ?? '';
        final done = event['done'] as bool? ?? false;
        setState(() {
          if (_messages.isNotEmpty && _messages.last.role == 'assistant' && !done) {
            _messages.last = ChatMessage(role: 'assistant', content: text);
          } else if (_messages.isEmpty || _messages.last.role != 'assistant') {
            _messages.add(ChatMessage(role: 'assistant', content: text));
          } else {
            _messages.last = ChatMessage(role: 'assistant', content: text);
          }
        });
        _scrollToBottom();
        break;
      case 'error':
        final msg = event['message'] as String? ?? 'Unknown error';
        setState(() => _messages.add(ChatMessage(role: 'assistant', content: 'Error: $msg')));
        break;
    }
  }

  void _stopVoiceChat() {
    if (_voiceWs != null) {
      try { _voiceWs!.add(jsonEncode({'action': 'stop'})); _voiceWs!.close(); } catch (_) {}
      _voiceWs = null;
    }
    if (mounted) setState(() { _voiceMode = false; _voiceState = 'stopped'; });
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

    final history = _messages
        .where((m) => m != _messages.last)
        .toList()
        .reversed.take(10).toList().reversed
        .map((m) => m.toJson()).toList();

    try {
      final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
      final req = await client.postUrl(Uri.parse('$_baseUrl/chat'));
      req.headers.set('Content-Type', 'application/json; charset=utf-8');
      req.add(utf8.encode(jsonEncode({
        'message': text,
        'history': history,
        'stream': true,
        'model': _selectedModel,
      })));
      final resp = await req.close().timeout(const Duration(minutes: 2));

      setState(() => _messages.add(ChatMessage(role: 'assistant', content: '')));

      await for (final chunk in resp.transform(utf8.decoder)) {
        for (final line in chunk.split('\n')) {
          if (!line.startsWith('data: ')) continue;
          final payload = line.substring(6).trim();
          if (payload == '[DONE]') break;
          try {
            final data = jsonDecode(payload) as Map<String, dynamic>;
            if (data.containsKey('error')) {
              if (mounted) {
                setState(() {
                  _messages.last = ChatMessage(role: 'assistant',
                    content: 'Error: ${data['error']}');
                });
              }
              break;
            }
            if (data.containsKey('token')) {
              _streamBuffer += data['token'] as String;
              if (mounted) {
                setState(() {
                  _messages.last = ChatMessage(role: 'assistant', content: _streamBuffer);
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
        setState(() => _messages.add(ChatMessage(role: 'assistant', content: 'Error: $e')));
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
          duration: const Duration(milliseconds: 150), curve: Curves.easeOut);
      }
    });
  }

  void _clearChat() {
    _stopVoiceChat();
    setState(() { _messages.clear(); _streamBuffer = ''; });
  }

  // ── Build ──

  @override
  Widget build(BuildContext context) {
    return Column(children: [
      _header(),
      Expanded(
        child: _voiceMode ? _voiceChatView() : _chatView(),
      ),
      if (_modelReady && !_voiceMode) _inputBar(),
      if (!_modelReady && !_voiceMode)
        Padding(
          padding: const EdgeInsets.all(16),
          child: Text('GROQ_API_KEY not set — add it to .env',
            style: TextStyle(fontSize: 12, color: C.warning)),
        ),
    ]);
  }

  Widget _header() {
    final model = _currentModel;
    return Container(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 12),
      child: Row(children: [
        const Text('Chat', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700,
          color: C.text, letterSpacing: -0.5)),
        const SizedBox(width: 12),
        // Model selector dropdown
        _modelSelector(),
        const Spacer(),
        // Voice mode toggle
        if (_modelReady && _ttsAvailable) ...[
          GestureDetector(
            onTap: _toggleVoiceMode,
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: _voiceMode ? C.accent.withAlpha(20) : C.level2,
                  borderRadius: BorderRadius.circular(6),
                  border: _voiceMode ? Border.all(color: C.accent.withAlpha(60)) : null),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(_voiceMode ? Icons.mic_rounded : Icons.mic_none_rounded,
                    size: 14, color: _voiceMode ? C.accent : C.textMuted),
                  const SizedBox(width: 4),
                  Text(_voiceMode ? 'Voice On' : 'Voice',
                    style: TextStyle(fontSize: 11, color: _voiceMode ? C.accent : C.textMuted)),
                ]),
              ),
            ),
          ),
          const SizedBox(width: 6),
          _voiceSelector(),
        ],
        if (_messages.isNotEmpty) ...[
          const SizedBox(width: 8),
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
        ],
      ]),
    );
  }

  Widget _modelSelector() {
    final model = _currentModel;
    final statusColor = _modelReady ? C.success : C.textMuted;
    final statusLabel = _modelReady
        ? (model?.label ?? _selectedModel)
        : 'No API key';

    return PopupMenuButton<String>(
      onSelected: _onModelChanged,
      offset: const Offset(0, 36),
      color: C.level2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      itemBuilder: (_) {
        final items = <PopupMenuEntry<String>>[];
        items.add(const PopupMenuItem<String>(
          enabled: false, height: 24,
          child: Text('GROQ CLOUD', style: TextStyle(fontSize: 9, color: C.textMuted,
            fontWeight: FontWeight.w600, letterSpacing: 1)),
        ));
        for (final m in _models) {
          items.add(PopupMenuItem<String>(
            value: m.id,
            enabled: m.available,
            height: 40,
            child: Opacity(
              opacity: m.available ? 1.0 : 0.4,
              child: Row(children: [
                Icon(m.id == _selectedModel ? Icons.radio_button_checked_rounded
                    : Icons.radio_button_off_rounded,
                  size: 14, color: m.id == _selectedModel ? C.accent : C.textMuted),
                const SizedBox(width: 8),
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(m.label, style: const TextStyle(fontSize: 12, color: C.text)),
                  Text(m.description, style: const TextStyle(fontSize: 10, color: C.textSub)),
                ]),
              ]),
            ),
          ));
        }
        return items;
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: statusColor.withAlpha(20),
          borderRadius: BorderRadius.circular(6)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Container(width: 6, height: 6, decoration: BoxDecoration(
            shape: BoxShape.circle, color: statusColor)),
          const SizedBox(width: 6),
          Icon(Icons.cloud_rounded, size: 11, color: statusColor),
          const SizedBox(width: 4),
          Text(statusLabel, style: TextStyle(fontSize: 11, color: statusColor,
            fontWeight: FontWeight.w500)),
          const SizedBox(width: 4),
          Icon(Icons.expand_more_rounded, size: 14, color: statusColor),
        ]),
      ),
    );
  }

  Widget _voiceSelector() {
    final activePath = widget.settings.activeVoicePath;
    String activeLabel = 'Select voice';
    for (final v in _builtinVoices) {
      if (v.path == activePath) {
        activeLabel = voiceDisplayName(v.name);
        break;
      }
    }
    // Also check custom voices (path might not be builtin)
    if (activeLabel == 'Select voice' && activePath.isNotEmpty) {
      final stem = activePath.split('/').last.replaceAll(RegExp(r'\.[^.]+$'), '');
      activeLabel = voiceDisplayName(stem);
    }

    return PopupMenuButton<String>(
      onSelected: (path) {
        setState(() {
          widget.settings.activeVoicePath = path;
          widget.settings.save();
        });
      },
      offset: const Offset(0, 36),
      color: C.level2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      itemBuilder: (_) {
        final items = <PopupMenuEntry<String>>[];
        items.add(const PopupMenuItem<String>(
          enabled: false, height: 22,
          child: Text('VOICE', style: TextStyle(fontSize: 9, color: C.textMuted,
            fontWeight: FontWeight.w600, letterSpacing: 1)),
        ));
        for (final v in _builtinVoices) {
          final label = voiceDisplayName(v.name);
          final isActive = v.path == activePath;
          items.add(PopupMenuItem<String>(
            value: v.path, height: 34,
            child: Row(children: [
              Icon(isActive ? Icons.radio_button_checked_rounded : Icons.radio_button_off_rounded,
                size: 13, color: isActive ? C.accent : C.textMuted),
              const SizedBox(width: 6),
              Text(label, style: TextStyle(fontSize: 12,
                color: isActive ? C.accent : C.text,
                fontWeight: isActive ? FontWeight.w600 : FontWeight.w400)),
            ]),
          ));
        }
        return items;
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        decoration: BoxDecoration(color: C.level2, borderRadius: BorderRadius.circular(6)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.record_voice_over_rounded, size: 12, color: C.textMuted),
          const SizedBox(width: 4),
          Text(activeLabel, style: const TextStyle(fontSize: 11, color: C.text, fontWeight: FontWeight.w500)),
          const SizedBox(width: 2),
          Icon(Icons.expand_more_rounded, size: 14, color: C.textMuted),
        ]),
      ),
    );
  }

  // ── Voice chat view ──

  Widget _voiceChatView() {
    return Column(children: [
      Expanded(
        child: _messages.isEmpty
          ? Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
              _voiceOrb(),
              const SizedBox(height: 20),
              Text(_voiceStateLabel(), style: const TextStyle(fontSize: 14, color: C.textSub)),
              const SizedBox(height: 4),
              const Text('Speak naturally — no button needed',
                style: TextStyle(fontSize: 11, color: C.textMuted)),
            ]))
          : Column(children: [
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  _voiceOrbSmall(),
                  const SizedBox(width: 10),
                  Text(_voiceStateLabel(), style: const TextStyle(fontSize: 12, color: C.textSub)),
                ]),
              ),
              Expanded(
                child: ListView.builder(
                  controller: _scrollController,
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 4),
                  itemCount: _messages.length,
                  itemBuilder: (_, i) => _messageBubble(_messages[i]),
                ),
              ),
            ]),
      ),
      Padding(
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
        child: GestureDetector(
          onTap: _stopVoiceChat,
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 12),
              decoration: BoxDecoration(
                color: C.error.withAlpha(15), borderRadius: BorderRadius.circular(10),
                border: Border.all(color: C.error.withAlpha(40))),
              child: const Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                Icon(Icons.stop_rounded, size: 18, color: C.error),
                SizedBox(width: 6),
                Text('Stop Voice Chat',
                  style: TextStyle(fontSize: 13, color: C.error, fontWeight: FontWeight.w500)),
              ]),
            ),
          ),
        ),
      ),
    ]);
  }

  String _voiceStateLabel() {
    switch (_voiceState) {
      case 'listening': return 'Listening...';
      case 'processing': return 'Thinking...';
      case 'speaking': return 'Speaking...';
      case 'connecting': return 'Connecting...';
      default: return 'Ready';
    }
  }

  Color _voiceOrbColor() {
    switch (_voiceState) {
      case 'listening': return C.accent;
      case 'processing': return C.warning;
      case 'speaking': return C.success;
      default: return C.textMuted;
    }
  }

  Widget _voiceOrb() {
    final color = _voiceOrbColor();
    final isActive = _voiceState == 'listening' || _voiceState == 'speaking';
    return AnimatedContainer(
      duration: const Duration(milliseconds: 400),
      width: isActive ? 100 : 80, height: isActive ? 100 : 80,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: color.withAlpha(isActive ? 30 : 15),
        border: Border.all(color: color.withAlpha(isActive ? 120 : 50), width: 2),
        boxShadow: isActive ? [BoxShadow(color: color.withAlpha(30), blurRadius: 24, spreadRadius: 4)] : []),
      child: Icon(
        _voiceState == 'speaking' ? Icons.volume_up_rounded :
        _voiceState == 'processing' ? Icons.psychology_rounded : Icons.mic_rounded,
        size: 36, color: color),
    );
  }

  Widget _voiceOrbSmall() {
    final color = _voiceOrbColor();
    return Container(
      width: 28, height: 28,
      decoration: BoxDecoration(shape: BoxShape.circle,
        color: color.withAlpha(20), border: Border.all(color: color.withAlpha(80))),
      child: Icon(
        _voiceState == 'speaking' ? Icons.volume_up_rounded :
        _voiceState == 'processing' ? Icons.psychology_rounded : Icons.mic_rounded,
        size: 14, color: color),
    );
  }

  Widget _chatView() {
    if (_messages.isEmpty) {
      final model = _currentModel;
      return Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.chat_bubble_outline_rounded, size: 40, color: C.textMuted.withAlpha(60)),
        const SizedBox(height: 12),
        const Text('Start a conversation', style: TextStyle(fontSize: 14, color: C.textMuted)),
        const SizedBox(height: 4),
        Text('Powered by Groq · ${model?.label ?? ''}',
          style: const TextStyle(fontSize: 11, color: C.textMuted)),
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
              child: Icon(Icons.cloud_rounded,
                size: 16, color: C.accent),
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
                style: TextStyle(fontSize: 13, color: C.text, height: 1.5,
                  fontStyle: msg.content.isEmpty && _loading ? FontStyle.italic : FontStyle.normal),
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
                contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12)),
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
