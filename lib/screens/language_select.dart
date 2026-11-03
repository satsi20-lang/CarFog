import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/app_state.dart';
import '../services/i18n_service.dart';
import '../widgets/fog_background.dart';
import '../widgets/lang_switcher.dart';
import '../widgets/portrait_ui.dart';

// Экран выбора языка: кнопки — показываемые языки (spec ∩ released, порядок
// spec) с родными названиями из manifest. Заголовок — language_select.title
// на каждом показываемом языке. Один язык — экран пропускается
// (AppNotifier.initLanguage).
//   * 2–6 языков — один столбец крупных кнопок;
//   * 7–24 — сетка в 2 столбца, прокрутка при необходимости.
class LanguageSelectScreen extends StatelessWidget {
  const LanguageSelectScreen({super.key});

  static const int maxSingleColumn = 6;

  @override
  Widget build(BuildContext context) {
    final langs = context.watch<AppNotifier>().displayLangs;
    final titles = <String>[];
    for (final l in langs) {
      final t = I18n.tr(l, 'language_select.title');
      if (!titles.contains(t)) titles.add(t);
    }
    final grid = langs.length > maxSingleColumn;
    // До 3 языков — заголовок строками крупно, как раньше; больше — одной
    // строкой через точку меньшим шрифтом, чтобы осталось место кнопкам.
    final title = Text(
      titles.length <= 3 ? titles.join('\n') : titles.join(' · '),
      textAlign: TextAlign.center,
      style: TextStyle(
        color: Colors.white,
        fontSize: titles.length <= 3 ? PUi.titleSp : PUi.bodySp + 2,
        fontWeight: FontWeight.bold,
        height: titles.length <= 3 ? 1.5 : 1.35,
      ),
    );

    void select(String lang) {
      final notifier = context.read<AppNotifier>();
      notifier.setLanguage(lang);
      notifier.transition(AppState.standby);
    }

    if (PUi.landscape) {
      return _buildLandscape(context, langs, titles, select);
    }

    return Scaffold(
      body: FogBackground(
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: PUi.gutter),
            child: PortraitScroll(
              child: Column(
                children: [
                  const Spacer(),
                  const SizedBox(height: 32),
                  title,
                  SizedBox(height: grid ? 40 : 72),
                  Center(
                    child: LangButtonGrid(
                      langs: langs,
                      // 520 — на SY156-A510; на узком IXP101M1 (533 dp)
                      // не шире экрана без полей.
                      width: grid
                          ? MediaQuery.sizeOf(context).width - PUi.gutter * 2
                          : math.min(
                              520,
                              MediaQuery.sizeOf(context).width - PUi.gutter * 2,
                            ),
                      columns: grid ? 2 : 1,
                      buttonHeight: grid ? PUi.buttonH : PUi.buttonH + 16,
                      fontSize: 32,
                      spacing: grid ? 16 : 28,
                      onSelect: select,
                    ),
                  ),
                  const SizedBox(height: 32),
                  const Spacer(),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  // Альбом 853x533 dp (IXP101M1): заголовки сверху, кнопки языков в ряд
  // (до 4 в ряду). Очень много языков — прокрутка (как и в портрете).
  Widget _buildLandscape(
    BuildContext context,
    List<String> langs,
    List<String> titles,
    void Function(String) select,
  ) {
    final m = PUi.m;
    final columns = math.min(langs.length, 4);
    return Scaffold(
      body: FogBackground(
        child: SafeArea(
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: m.gutter + 24),
            child: PortraitScroll(
              child: Column(
                children: [
                  const Spacer(),
                  Text(
                    titles.length <= 3 ? titles.join('\n') : titles.join(' · '),
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: titles.length <= 3 ? m.titleSp : m.bodySp,
                      fontWeight: FontWeight.bold,
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: 40),
                  Center(
                    child: LangButtonGrid(
                      langs: langs,
                      width: math.min(
                        200.0 * columns + 20 * (columns - 1),
                        MediaQuery.sizeOf(context).width - (m.gutter + 24) * 2,
                      ),
                      columns: columns,
                      buttonHeight: m.buttonH + 12,
                      fontSize: 26,
                      spacing: 20,
                      onSelect: select,
                    ),
                  ),
                  const Spacer(),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
