import 'package:flutter/material.dart';
import 'portrait_ui.dart';

class LangSwitcher extends StatelessWidget {
  final String current;
  final ValueChanged<String> onChanged;

  const LangSwitcher({super.key, required this.current, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: ['et', 'en', 'ru'].map((lang) {
        final isActive = current == lang;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () => onChanged(lang),
          child: Container(
            margin: const EdgeInsets.only(left: 8),
            constraints: const BoxConstraints(
              minWidth: PUi.langW,
              minHeight: PUi.langH,
            ),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: isActive ? const Color(0xFF00C6B2).withValues(alpha: 0.15) : Colors.transparent,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: isActive ? const Color(0xFF00C6B2) : const Color(0xFF334455),
                width: isActive ? 2 : 1,
              ),
            ),
            child: Text(
              lang.toUpperCase(),
              style: TextStyle(
                color: isActive ? const Color(0xFF00C6B2) : const Color(0xFF8899AA),
                fontSize: 24,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        );
      }).toList(),
    );
  }
}
