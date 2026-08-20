import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/app_state.dart';
import '../widgets/lang_switcher.dart';

const Map<String, Map<String, String>> i18n = {
  'ru': {
    'title': 'ВЫБЕРИТЕ АРОМАТ',
    'hint': 'Серым отмечены временно недоступные ароматы',
    'unavailable': '(недоступно)',
    'cancel': 'Отмена',
  },
  'en': {
    'title': 'CHOOSE A FRAGRANCE',
    'hint': 'Greyed-out fragrances are temporarily unavailable',
    'unavailable': '(unavailable)',
    'cancel': 'Cancel',
  },
  'et': {
    'title': 'VALI LÕHN',
    'hint': 'Hallid lõhnad on ajutiselt saadaval',
    'unavailable': '(pole saadaval)',
    'cancel': 'Tühista',
  },
};

class SelectFlavorScreen extends StatelessWidget {
  const SelectFlavorScreen({super.key});

  // Сетка подстраивается под kFlavorCount: до 4 ароматов — в один ряд
  // (широкие карточки на весь альбомный экран), больше — переносится
  // на несколько рядов по 4 в ряд.
  int get _crossAxisCount => kFlavorCount <= 4 ? kFlavorCount : 4;

  @override
  Widget build(BuildContext context) {
    final notifier = context.watch<AppNotifier>();
    final lang = notifier.lang;
    final levels = notifier.levels;
    final names = notifier.config.flavorNames[lang]!;
    final t = i18n[lang]!;

    return Scaffold(
      body: SafeArea(
        child: Row(
          children: [
            // Левая колонка: заголовок, подсказка, отмена — фиксированная
            // ширина, чтобы сетка ароматов получила максимум пространства.
            SizedBox(
              width: 280,
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    LangSwitcher(current: lang, onChanged: notifier.setLanguage),
                    const SizedBox(height: 24),
                    Text(
                      t['title']!,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 26,
                        fontWeight: FontWeight.bold,
                        height: 1.2,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      t['hint']!,
                      style: const TextStyle(color: Colors.white60, fontSize: 13),
                    ),
                    const Spacer(),
                    SizedBox(
                      width: double.infinity,
                      height: 52,
                      child: OutlinedButton(
                        onPressed: () => context
                            .read<AppNotifier>()
                            .transition(AppState.standby),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.white60,
                          side: const BorderSide(color: Colors.white30),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                        child: Text(
                          t['cancel']!,
                          style: const TextStyle(fontSize: 16),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),

            // Правая часть: сетка ароматов
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(0, 24, 24, 24),
                child: GridView.builder(
                  gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: _crossAxisCount,
                    childAspectRatio: 1.3,
                    crossAxisSpacing: 16,
                    mainAxisSpacing: 16,
                  ),
                  itemCount: kFlavorCount,
                  itemBuilder: (context, i) {
                    final available = levels.length > i ? levels[i] : false;
                    return GestureDetector(
                      onTap: available
                          ? () => context.read<AppNotifier>().selectFlavor(i)
                          : null,
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        decoration: BoxDecoration(
                          color: available
                              ? const Color(0xFF2E2E2E)
                              : const Color(0xFF3A3A3A),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: available
                                ? const Color(0xFF2EC4B6)
                                : Colors.grey,
                            width: 1.5,
                          ),
                        ),
                        child: Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(
                                names.length > i ? names[i] : '',
                                style: TextStyle(
                                  color: available ? Colors.white : Colors.grey,
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              if (!available)
                                Text(
                                  t['unavailable']!,
                                  style: const TextStyle(
                                    color: Colors.grey,
                                    fontSize: 12,
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
