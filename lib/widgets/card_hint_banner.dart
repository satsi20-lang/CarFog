import 'dart:async';

import 'package:flutter/material.dart';

import '../services/card_terminal_service.dart';
import 'portrait_ui.dart';

// Подсказка «Сначала выберите запах» (1.11.0, решение владельца 21.10.2026):
// клиент приложил карту, не выбрав запах — терминал закрыл сессию 13 04 без
// списания, на экране на несколько секунд появляется подсказка.
class CardHintBanner extends StatefulWidget {
  final String text;
  const CardHintBanner({super.key, required this.text});

  static const Duration showFor = Duration(seconds: 6);

  // Подменяется в тестах (без реального ожидания 6 с).
  @visibleForTesting
  static DateTime Function() clock = DateTime.now;

  @override
  State<CardHintBanner> createState() => _CardHintBannerState();
}

class _CardHintBannerState extends State<CardHintBanner> {
  Timer? _hide;

  bool get _visible {
    final at = CardTerminalService.tappedWithoutFlavorAt.value;
    return at != null && CardHintBanner.clock().difference(at) < CardHintBanner.showFor;
  }

  void _changed() {
    if (!mounted) return;
    setState(() {});
    _hide?.cancel();
    if (_visible) _hide = Timer(CardHintBanner.showFor, () => mounted ? setState(() {}) : null);
  }

  @override
  void initState() {
    super.initState();
    CardTerminalService.tappedWithoutFlavorAt.addListener(_changed);
  }

  @override
  void dispose() {
    _hide?.cancel();
    CardTerminalService.tappedWithoutFlavorAt.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_visible) return const SizedBox.shrink();
    return Container(
      key: const ValueKey('card_hint_banner'),
      margin: const EdgeInsets.symmetric(vertical: 8),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      decoration: BoxDecoration(
        color: const Color(0xFFFFB020).withValues(alpha: 0.18),
        border: Border.all(color: const Color(0xFFFFB020), width: 2),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.contactless, color: Color(0xFFFFB020), size: 40),
          const SizedBox(width: 12),
          Flexible(
            child: Text(
              widget.text,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white,
                fontSize: PUi.bodySp + 4,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
