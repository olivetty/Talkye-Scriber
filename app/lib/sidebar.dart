import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'theme.dart';

enum NavSection { interpreter, dictate, chat, assistant, calendar, voice, settings }

class Sidebar extends StatelessWidget {
  final NavSection active;
  final ValueChanged<NavSection> onSelect;
  final bool engineRunning;

  const Sidebar({super.key, required this.active, required this.onSelect, this.engineRunning = false});

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      child: BackdropFilter(
        filter: C.blur,
        child: Container(
          width: 200,
          color: C.glass,
          child: Column(children: [
            const SizedBox(height: 20),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(children: [
                SvgPicture.asset('assets/navbar-icon.svg',
                  width: 22, height: 22,
                  colorFilter: ColorFilter.mode(
                    engineRunning ? C.orange : C.text, BlendMode.srcIn)),
                const SizedBox(width: 10),
                const Text('Talkye Meet',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700,
                    color: C.text, letterSpacing: -0.3)),
              ]),
            ),
            const SizedBox(height: 24),
            _NavItem(icon: Icons.translate_rounded, label: 'Interpreter',
              section: NavSection.interpreter, active: active, onTap: onSelect),
            _NavItem(icon: Icons.keyboard_voice_rounded, label: 'Scriber',
              section: NavSection.dictate, active: active, onTap: onSelect),
            _NavItem(icon: Icons.smart_toy_outlined, label: 'Chat',
              section: NavSection.chat, active: active, onTap: onSelect),
            _NavItem(icon: Icons.groups_rounded, label: 'Assistant',
              section: NavSection.assistant, active: active, onTap: onSelect, badge: 'Soon'),
            _NavItem(icon: Icons.calendar_month_rounded, label: 'Calendar',
              section: NavSection.calendar, active: active, onTap: onSelect, badge: 'Soon'),
            const SizedBox(height: 16),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Container(height: 1, color: C.textMuted.withAlpha(25)),
            ),
            const SizedBox(height: 16),
            _NavItem(icon: Icons.mic_rounded, label: 'Voice Clone',
              section: NavSection.voice, active: active, onTap: onSelect),
            _NavItem(icon: Icons.settings_rounded, label: 'Settings',
              section: NavSection.settings, active: active, onTap: onSelect),
            const Spacer(),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text('v0.2.1', style: TextStyle(fontSize: 10, color: C.textMuted.withAlpha(80))),
            ),
          ]),
        ),
      ),
    );
  }
}

class _NavItem extends StatefulWidget {
  final IconData icon;
  final String label;
  final NavSection section;
  final NavSection active;
  final ValueChanged<NavSection> onTap;
  final String? badge;

  const _NavItem({
    required this.icon, required this.label, required this.section,
    required this.active, required this.onTap, this.badge,
  });

  @override
  State<_NavItem> createState() => _NavItemState();
}

class _NavItemState extends State<_NavItem> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final isActive = widget.active == widget.section;
    final bg = isActive ? C.accent.withAlpha(20) : (_hovered ? C.level2 : Colors.transparent);
    final color = isActive ? C.accent : (_hovered ? C.text : C.textSub);

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () => widget.onTap(widget.section),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(10)),
          child: Row(children: [
            if (isActive)
              Container(width: 3, height: 18, margin: const EdgeInsets.only(right: 10),
                decoration: BoxDecoration(color: C.accent, borderRadius: BorderRadius.circular(2)))
            else
              const SizedBox(width: 13),
            Icon(widget.icon, size: 18, color: color),
            const SizedBox(width: 10),
            Expanded(child: Text(widget.label,
              style: TextStyle(fontSize: 13, color: color,
                fontWeight: isActive ? FontWeight.w600 : FontWeight.w400))),
            if (widget.badge != null)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: C.textMuted.withAlpha(25), borderRadius: BorderRadius.circular(4)),
                child: Text(widget.badge!,
                  style: const TextStyle(fontSize: 9, color: C.textMuted, fontWeight: FontWeight.w500)),
              ),
          ]),
        ),
      ),
    );
  }
}
