import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/app_state.dart';
import '../widgets/fog_background.dart';
import '../widgets/lang_switcher.dart';
import '../widgets/portrait_ui.dart';

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

  // Портрет 720x1280 dp: ароматы — крупные карточки в 2 колонки (при 4
  // ароматах 2x2, при 8 — 2x4 с прокруткой, если не помещаются).
  static const int _crossAxisCount = 2;

  @override
  Widget build(BuildContext context) {
    final notifier = context.watch<AppNotifier>();
    final lang = notifier.lang;
    final levels = notifier.levels;
    final names = notifier.config.flavorNames[lang]!;
    final t = i18n[lang]!;

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
                    onChanged: notifier.setLanguage,
                  ),
                ),
                const SizedBox(height: 32),
                Text(
                  t['title']!,
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
                  t['hint']!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white60,
                    fontSize: PUi.minBodySp,
                  ),
                ),
                const SizedBox(height: 28),
                // Сетка занимает всё свободное место; не помещается —
                // прокручивается.
                Expanded(
                  child: GridView.builder(
                    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: _crossAxisCount,
                      childAspectRatio: 1.15,
                      crossAxisSpacing: 24,
                      mainAxisSpacing: 24,
                    ),
                    itemCount: kFlavorCount,
                    itemBuilder: (context, i) {
                      final available = levels.length > i ? levels[i] : false;
                      return GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: available
                            ? () => context.read<AppNotifier>().selectFlavor(i)
                            : null,
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 200),
                          decoration: BoxDecoration(
                            color: available
                                ? const Color(0xFF2E2E2E)
                                : const Color(0xFF3A3A3A),
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(
                              color: available
                                  ? const Color(0xFF2EC4B6)
                                  : Colors.grey,
                              width: 2,
                            ),
                          ),
                          child: Center(
                            child: Padding(
                              padding: const EdgeInsets.all(12),
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  FittedBox(
                                    fit: BoxFit.scaleDown,
                                    child: Text(
                                      names.length > i ? names[i] : '',
                                      style: TextStyle(
                                        color: available
                                            ? Colors.white
                                            : Colors.grey,
                                        fontSize: PUi.titleSp,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ),
                                  if (!available)
                                    Padding(
                                      padding: const EdgeInsets.only(top: 8),
                                      child: Text(
                                        t['unavailable']!,
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
                    },
                  ),
                ),
                const SizedBox(height: 24),
                SizedBox(
                  height: PUi.buttonH,
                  child: OutlinedButton(
                    onPressed: () =>
                        context.read<AppNotifier>().transition(AppState.standby),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white70,
                      side: const BorderSide(color: Colors.white38, width: 2),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    child: Text(
                      t['cancel']!,
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
