import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/app_state.dart';
import '../services/i18n_service.dart';
import '../widgets/card_hint_banner.dart';
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
    // Цена каждого запаха (1.11.0), в том же виде, что на экране оплаты.
    final prices = [
      for (var i = 0; i < count; i++)
        '${(notifier.config.priceForFlavor(i) / 100).toStringAsFixed(2)} €',
    ];
    String t(String key) => I18n.tr(lang, 'select_flavor.$key');

    if (PUi.landscape) {
      return _buildLandscape(context, notifier, names, prices, t);
    }

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
                // Карту приложили до выбора запаха (1.11.0).
                CardHintBanner(text: t('card_hint')),
                const SizedBox(height: 28),
                // Сетка: 2 колонки; число карточек = число насосов из spec (4…8):
                // 4 → 2 ряда, 5–6 → 3, 7–8 → 4. Нечётная последняя карточка
                // ЦЕНТРИРУЕТСЯ в своём ряду. Не помещается — прокрутка.
                Expanded(
                  child: _FlavorGrid(
                    count: count,
                    names: names,
                    prices: prices,
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
  // Альбом (IXP101M1, 853x533 dp): шапка слева, язык справа; сетка до 4
  // карточек в ряд и не больше 2 рядов (4 → 4x1, 5–6 → 3x2, 7–8 → 4x2),
  // без прокрутки; баннер карты — поверх сетки, раскладку не сдвигает.
  Widget _buildLandscape(
    BuildContext context,
    AppNotifier notifier,
    List<String> names,
    List<String> prices,
    String Function(String) t,
  ) {
    final m = PUi.m;
    final count = notifier.config.activeFlavorCount;
    return Scaffold(
      body: FogBackground(
        child: SafeArea(
          child: Padding(
            padding: EdgeInsets.fromLTRB(m.gutter, 12, m.gutter, m.gutter - 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                LandscapeHeader(
                  title: t('title'),
                  subtitle: t('hint'),
                  trailing: LangSwitcher(
                    current: notifier.lang,
                    langs: notifier.displayLangs,
                    onChanged: notifier.setLanguage,
                  ),
                ),
                const SizedBox(height: 12),
                Expanded(
                  child: Stack(
                    children: [
                      Positioned.fill(
                        child: _FlavorGrid(
                          count: count,
                          names: names,
                          prices: prices,
                          levels: notifier.levels,
                          unavailable: t('unavailable'),
                          columns: count <= 4 ? count : (count / 2).ceil(),
                          spacing: 14,
                          onSelect: (i) =>
                              context.read<AppNotifier>().selectFlavor(i),
                        ),
                      ),
                      Align(
                        alignment: Alignment.topCenter,
                        child: CardHintBanner(text: t('card_hint')),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                LandscapeCancelButton(
                  text: t('cancel'),
                  onPressed: () => context.read<AppNotifier>().transition(
                    AppState.standby,
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
  final List<String> prices;
  final List<bool> levels;
  final String unavailable;
  final void Function(int) onSelect;
  // Портрет — 2 колонки (прежняя раскладка); альбом задаёт свои.
  final int columns;
  final double spacing;

  const _FlavorGrid({
    required this.count,
    required this.names,
    required this.prices,
    required this.levels,
    required this.unavailable,
    required this.onSelect,
    this.columns = 2,
    this.spacing = 24,
  });

  static const double _spacing = 24;
  static const double _minCardH = 120;

  @override
  Widget build(BuildContext context) {
    if (PUi.landscape) return _buildFixed(context);
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
            price: prices.length > i ? prices[i] : '',
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

extension on _FlavorGrid {
  // Альбом: все карточки в columns колонок, высота делится поровну — без
  // прокрутки. Неполный последний ряд центрируется.
  Widget _buildFixed(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        final rows = (count / columns).ceil();
        final cellW = (box.maxWidth - spacing * (columns - 1)) / columns;
        final cellH = (box.maxHeight - spacing * (rows - 1)) / rows;
        Widget card(int i) => SizedBox(
          width: cellW,
          height: cellH,
          child: _FlavorCard(
            name: names.length > i ? names[i] : '',
            price: prices.length > i ? prices[i] : '',
            available: levels.length > i ? levels[i] : false,
            unavailable: unavailable,
            onTap: () => onSelect(i),
          ),
        );
        return Column(
          children: [
            for (var r = 0; r < rows; r++) ...[
              if (r > 0) SizedBox(height: spacing),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  for (var c = 0; c < columns; c++)
                    if (r * columns + c < count) ...[
                      if (c > 0) SizedBox(width: spacing),
                      card(r * columns + c),
                    ],
                ],
              ),
            ],
          ],
        );
      },
    );
  }
}

class _FlavorCard extends StatelessWidget {
  final String name;
  final String price;
  final bool available;
  final String unavailable;
  final VoidCallback onTap;

  const _FlavorCard({
    required this.name,
    required this.price,
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
            padding: EdgeInsets.all(PUi.landscape ? 8 : 12),
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
                          fontSize: PUi.m.titleSp,
                          fontWeight: FontWeight.bold,
                          height: 1.1,
                        ),
                      ),
                    ),
                  ),
                ),
                if (price.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        price,
                        key: const ValueKey('flavor_price'),
                        style: TextStyle(
                          color: available
                              ? const Color(0xFF2EC4B6)
                              : Colors.grey,
                          fontSize: PUi.m.bodySp + 4,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                if (!available)
                  Padding(
                    padding: EdgeInsets.only(top: PUi.landscape ? 4 : 8),
                    child: Text(
                      unavailable,
                      textAlign: TextAlign.center,
                      maxLines: PUi.landscape ? 1 : null,
                      overflow: PUi.landscape ? TextOverflow.ellipsis : null,
                      style: TextStyle(
                        color: Colors.grey,
                        fontSize: PUi.m.minBodySp,
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
