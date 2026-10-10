import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/app_state.dart';
import '../services/i18n_service.dart';
import 'portrait_ui.dart';

const _accent = Color(0xFF00C6B2);

// Переключатель языка на экранах. langs — показываемые языки (порядок = spec):
//   * один язык — переключателя нет;
//   * 2–3 — кнопки с кодами (ET/EN/RU), как в 1.8.0;
//   * больше 3 — компактная кнопка с кодом текущего языка, по нажатию окно со
//     всеми языками (родные названия). Выбор не прерывает экран: окно
//     закрывается, экран (оплата, обработка) продолжает работать.
class LangSwitcher extends StatelessWidget {
  final String current;
  final List<String> langs;
  final ValueChanged<String> onChanged;

  // Больше этого числа — компактная кнопка с окном выбора.
  static const int maxInline = 3;

  const LangSwitcher({
    super.key,
    required this.current,
    required this.langs,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    if (langs.length <= 1) return const SizedBox.shrink();
    if (langs.length > maxInline) {
      return _CompactLangButton(
        current: current,
        langs: langs,
        onChanged: onChanged,
      );
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: langs.map((lang) {
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
              color: isActive
                  ? _accent.withValues(alpha: 0.15)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: isActive ? _accent : const Color(0xFF334455),
                width: isActive ? 2 : 1,
              ),
            ),
            child: Text(
              lang.toUpperCase(),
              style: TextStyle(
                color: isActive ? _accent : const Color(0xFF8899AA),
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

class _CompactLangButton extends StatelessWidget {
  final String current;
  final List<String> langs;
  final ValueChanged<String> onChanged;

  const _CompactLangButton({
    required this.current,
    required this.langs,
    required this.onChanged,
  });

  Future<void> _open(BuildContext context) async {
    final picked = await showDialog<String>(
      context: context,
      builder: (_) => LangPickerDialog(current: current, langs: langs),
    );
    if (picked != null) onChanged(picked);
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      key: const ValueKey('lang_compact'),
      behavior: HitTestBehavior.opaque,
      onTap: () => _open(context),
      child: Container(
        margin: const EdgeInsets.only(left: 8),
        padding: const EdgeInsets.symmetric(horizontal: 14),
        constraints: const BoxConstraints(
          minWidth: PUi.langW,
          minHeight: PUi.langH,
        ),
        decoration: BoxDecoration(
          color: _accent.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: _accent, width: 2),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.language, color: _accent, size: 30),
            const SizedBox(width: 8),
            Text(
              current.toUpperCase(),
              style: const TextStyle(
                color: _accent,
                fontSize: 24,
                fontWeight: FontWeight.bold,
              ),
            ),
            const Icon(Icons.arrow_drop_down, color: _accent, size: 30),
          ],
        ),
      ),
    );
  }
}

// Окно выбора языка: сетка родных названий в 2 столбца, прокрутка при
// необходимости. Закрывается само, если экран под ним сменился (оплата
// завершилась, сессия сброшена), чтобы не висеть поверх другого экрана.
class LangPickerDialog extends StatefulWidget {
  final String current;
  final List<String> langs;

  const LangPickerDialog({
    super.key,
    required this.current,
    required this.langs,
  });

  @override
  State<LangPickerDialog> createState() => _LangPickerDialogState();
}

class _LangPickerDialogState extends State<LangPickerDialog> {
  AppState? _openedOn;

  @override
  Widget build(BuildContext context) {
    final state = Provider.of<AppNotifier?>(context)?.state;
    _openedOn ??= state;
    if (state != _openedOn) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && Navigator.of(context).canPop()) {
          Navigator.of(context).pop();
        }
      });
    }
    return Dialog(
      backgroundColor: const Color(0xFF1E2633),
      insetPadding: const EdgeInsets.all(PUi.gutter),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: const BorderSide(color: _accent, width: 2),
      ),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Icon(Icons.language, color: _accent, size: 36),
                const Spacer(),
                SizedBox(
                  width: PUi.langH,
                  height: PUi.langH,
                  child: IconButton(
                    key: const ValueKey('lang_picker_close'),
                    icon: const Icon(
                      Icons.close,
                      color: Colors.white70,
                      size: 36,
                    ),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Flexible(
              child: SingleChildScrollView(
                child: LangButtonGrid(
                  langs: widget.langs,
                  current: widget.current,
                  width: MediaQuery.sizeOf(context).width - PUi.gutter * 2 - 40,
                  columns: 2,
                  buttonHeight: PUi.buttonH,
                  fontSize: 28,
                  onSelect: (l) => Navigator.of(context).pop(l),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// Кнопки языков с родными названиями (экран выбора языка и окно выбора).
// Ширина задаётся явно (без LayoutBuilder: экран выбора языка лежит в
// PortraitScroll, где нужен расчёт собственной высоты). Длинные названия
// переносятся на 2 строки и при необходимости уменьшаются — кнопка не
// переполняется.
class LangButtonGrid extends StatelessWidget {
  final List<String> langs;
  final String? current;
  final double width;
  final int columns;
  final double buttonHeight;
  final double fontSize;
  final double spacing;
  final ValueChanged<String> onSelect;

  const LangButtonGrid({
    super.key,
    required this.langs,
    required this.width,
    required this.onSelect,
    this.current,
    this.columns = 1,
    this.buttonHeight = PUi.buttonH,
    this.fontSize = 32,
    this.spacing = 16,
  });

  @override
  Widget build(BuildContext context) {
    final w = (width - spacing * (columns - 1)) / columns;
    Widget button(String l) => SizedBox(
      width: w,
      height: buttonHeight,
      child: _LangButton(
        code: l,
        label: I18n.nativeName(l),
        active: l == current,
        fontSize: fontSize,
        textWidth: w - 24,
        onTap: () => onSelect(l),
      ),
    );
    final rows = <Widget>[];
    for (var i = 0; i < langs.length; i += columns) {
      if (i > 0) rows.add(SizedBox(height: spacing));
      rows.add(
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var j = i; j < i + columns && j < langs.length; j++) ...[
              if (j > i) SizedBox(width: spacing),
              button(langs[j]),
            ],
          ],
        ),
      );
    }
    return Column(mainAxisSize: MainAxisSize.min, children: rows);
  }
}

class _LangButton extends StatelessWidget {
  final String code;
  final String label;
  final bool active;
  final double fontSize;
  final double textWidth;
  final VoidCallback onTap;

  const _LangButton({
    required this.code,
    required this.label,
    required this.active,
    required this.fontSize,
    required this.textWidth,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ElevatedButton(
      key: ValueKey('lang_$code'),
      onPressed: onTap,
      style: ElevatedButton.styleFrom(
        backgroundColor: active
            ? const Color(0xFF1F3B3A)
            : const Color(0xFF2E2E2E),
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        minimumSize: const Size(PUi.minTouch, PUi.minTouch),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: PUi.accent, width: active ? 3 : 2),
        ),
      ),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: textWidth),
          child: Text(
            label,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: fontSize,
              fontWeight: FontWeight.bold,
              height: 1.1,
            ),
          ),
        ),
      ),
    );
  }
}
