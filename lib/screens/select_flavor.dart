import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/app_state.dart';

// Названия ароматов на трёх языках
const Map<String, List<String>> flavorNames = {
  'ru': [
    'Лимон',
    'Вишня',
    'Хвоя',
    'Лаванда',
    'Океан',
    'Кофе',
    'Ваниль',
    'Мята',
  ],
  'en': [
    'Lemon',
    'Cherry',
    'Pine',
    'Lavender',
    'Ocean',
    'Coffee',
    'Vanilla',
    'Mint',
  ],
  'et': [
    'Sidrun',
    'Kirss',
    'Mänd',
    'Lavendel',
    'Ookean',
    'Kohv',
    'Vanilje',
    'Münt',
  ],
};

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

  @override
  Widget build(BuildContext context) {
    final notifier = context.watch<AppNotifier>();
    final lang = notifier.lang;
    final levels = notifier.levels;
    final names = flavorNames[lang]!;
    final t = i18n[lang]!;

    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            // Заголовок + переключатель языка
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      t['title']!,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  _LangSwitcher(),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: Text(
                t['hint']!,
                style: const TextStyle(color: Colors.white60, fontSize: 13),
              ),
            ),

            // Сетка ароматов 2×4
            Expanded(
              child: GridView.builder(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 2,
                  childAspectRatio: 2.2,
                  crossAxisSpacing: 12,
                  mainAxisSpacing: 12,
                ),
                itemCount: 8,
                itemBuilder: (context, i) {
                  final available = levels[i];
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
                              names[i],
                              style: TextStyle(
                                color: available ? Colors.white : Colors.grey,
                                fontSize: 17,
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

            // Кнопка отмены
            Padding(
              padding: const EdgeInsets.all(16),
              child: SizedBox(
                width: double.infinity,
                height: 52,
                child: OutlinedButton(
                  onPressed: () =>
                      context.read<AppNotifier>().transition(AppState.standby),
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
            ),
          ],
        ),
      ),
    );
  }
}

class _LangSwitcher extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final notifier = context.watch<AppNotifier>();
    final currentLang = notifier.lang;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: ['et', 'en', 'ru'].map((lang) {
        final isActive = lang == currentLang;
        return GestureDetector(
          onTap: () => notifier.setLanguage(lang),
          child: Container(
            margin: const EdgeInsets.only(left: 6),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: isActive ? const Color(0xFF2EC4B6) : Colors.transparent,
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: const Color(0xFF2EC4B6), width: 1),
            ),
            child: Text(
              lang.toUpperCase(),
              style: TextStyle(
                color: isActive ? Colors.black : Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 12,
              ),
            ),
          ),
        );
      }).toList(),
    );
  }
}
