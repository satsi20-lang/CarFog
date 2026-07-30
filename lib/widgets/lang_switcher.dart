import 'package:flutter/material.dart';

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
          onTap: () => onChanged(lang),
          child: Container(
            margin: const EdgeInsets.only(left: 4),
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 5),
            decoration: BoxDecoration(
              color: isActive ? const Color(0xFF00C6B2).withValues(alpha: 0.15) : Colors.transparent,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color: isActive ? const Color(0xFF00C6B2) : const Color(0xFF334455),
              ),
            ),
            child: Text(
              lang.toUpperCase(),
              style: TextStyle(
                color: isActive ? const Color(0xFF00C6B2) : const Color(0xFF556677),
                fontSize: 12,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        );
      }).toList(),
    );
  }
}
