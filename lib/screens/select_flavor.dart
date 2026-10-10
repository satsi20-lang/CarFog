import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/app_state.dart';
import '../services/i18n_service.dart';
import '../widgets/fog_background.dart';
import '../widgets/lang_switcher.dart';
import '../widgets/portrait_ui.dart';

class SelectFlavorScreen extends StatelessWidget {
  const SelectFlavorScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final notifier = context.watch<AppNotifier>();
    final lang = notifier.lang;
    final levels = notifier.levels;
    final count = notifier.config.activeFlavorCount;
    final names = [
      for (var i = 0; i < count; i++) notifier.config.flavorNameFor(lang, i),
    ];
    String t(String key) => I18n.tr(lang, 'select_flavor.$key');

    return Scaffold(
      body: FogBackground(
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(
              PUi.gutter,
              24,
              PUi.gutter,
              PUi.gutter,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Align(
                  alignment: Alignment.centerRight,
                  child: LangSwitcher(
                    current: lang,
                    langs: notifier.displayLangs,
                    onChanged: notifier.setLanguage,
                  ),
                ),
                const SizedBox(height: 32),
                Text(
                  t('title'),
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: PUi.titleSp,
                    fontWeight: FontWeight.bold,
                    height: 1.2,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  t('hint'),
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white60,
                    fontSize: PUi.minBodySp,
                  ),
                ),
                const SizedBox(height: 28),
                // Сетка: 2 колонки; число карточек = число насосов из spec (4…8):
                // 4 → 2 ряда, 5–6 → 3, 7–8 → 4. Нечётная последняя карточка
                // ЦЕНТРИРУЕТСЯ в своём ряду. Не помещается — прокрутка.
                Expanded(
                  child: _FlavorGrid(
                    count: count,
                    names: names,
                    levels: levels,
                    unavailable: t('unavailable'),
                    onSelect: (i) =>
                        context.read<AppNotifier>().selectFlavor(i),
                  ),
                ),
                const SizedBox(height: 24),
                SizedBox(
                  height: PUi.buttonH,
                  child: OutlinedButton(
                    onPressed: () => context.read<AppNotifier>().transition(
                      AppState.standby,
                    ),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white70,
                      side: const BorderSide(color: Colors.white38, width: 2),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    child: Text(
                      t('cancel'),
                      style: const TextStyle(fontSize: 28),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// Сетка карточек ароматов (2 колонки, до 8 карточек).
class _FlavorGrid extends StatelessWidget {
  final int count;
  final List<String> names;
  final List<bool> levels;
  final String unavailable;
  final void Function(int) onSelect;

  const _FlavorGrid({
    required this.count,
    required this.names,
    required this.levels,
    required this.unavailable,
    required this.onSelect,
  });

  static const double _spacing = 24;
  static const double _minCardH = 120;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        final rows = (count / 2).ceil();
        final cellW = (box.maxWidth - _spacing) / 2;
        final fit = (box.maxHeight - _spacing * (rows - 1)) / rows;
        // Карточки растягиваются по высоте, но не вытягиваются и не
        // становятся ниже минимума (меньше — прокрутка).
        final cellH = fit.clamp(_minCardH, cellW * 1.25);
        Widget card(int i) => SizedBox(
          width: cellW,
          height: cellH,
          child: _FlavorCard(
            name: names.length > i ? names[i] : '',
            available: levels.length > i ? levels[i] : false,
            unavailable: unavailable,
            onTap: () => onSelect(i),
          ),
        );
        return Center(
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var r = 0; r < rows; r++) ...[
                  if (r > 0) const SizedBox(height: _spacing),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      card(r * 2),
                      if (r * 2 + 1 < count) ...[
                        const SizedBox(width: _spacing),
                        card(r * 2 + 1),
                      ],
                    ],
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}

class _FlavorCard extends StatelessWidget {
  final String name;
  final bool available;
  final String unavailable;
  final VoidCallback onTap;

  const _FlavorCard({
    required this.name,
    required this.available,
    required this.unavailable,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: available ? onTap : null,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        decoration: BoxDecoration(
          color: available ? const Color(0xFF2E2E2E) : const Color(0xFF3A3A3A),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: available ? const Color(0xFF2EC4B6) : Colors.grey,
            width: 2,
          ),
        ),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // Название переносится на 2 строки; очень длинное сжимается.
                Flexible(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 280),
                      child: Text(
                        name,
                        textAlign: TextAlign.center,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: available ? Colors.white : Colors.grey,
                          fontSize: PUi.titleSp,
                          fontWeight: FontWeight.bold,
                          height: 1.1,
                        ),
                      ),
                    ),
                  ),
                ),
                if (!available)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      unavailable,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.grey,
                        fontSize: PUi.minBodySp,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
