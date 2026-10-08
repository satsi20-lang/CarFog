import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/app_state.dart';
import '../widgets/fog_background.dart';
import '../widgets/lang_switcher.dart';
import '../widgets/portrait_ui.dart';

// Экран "аппарат выведен из обслуживания" (задача "вывод аппарата из
// обслуживания", требования 6-7). Заменяет экран ожидания:
//   * только понятное сообщение — без технических подробностей и кодов;
//   * НИКАКИХ видео-заставок с SD-карты и вообще таймеров: аппарат не
//     должен выглядеть работающим;
//   * оплата отсюда недостижима (само состояние не ведёт ни на один экран
//     оплаты, а AppNotifier.transition() заворачивает любые попытки сюда
//     же).
// Выход один: долгое нажатие в левом верхнем углу — вход в сервисное меню
// по PIN (тот же жест, что на заставке и экране ошибки). Из меню техник
// прогоняет пробный цикл и снимает блокировку вручную.
class OutOfServiceScreen extends StatelessWidget {
  const OutOfServiceScreen({super.key});

  static const _texts = {
    'title': {
      'et': 'Seade on ajutiselt hooldusel',
      'en': 'Temporarily out of service',
      'ru': 'Аппарат временно не работает',
    },
    'detail': {
      'et': 'Makseid ei võeta vastu. Vabandame ebamugavuse pärast.',
      'en': 'Payments are not being accepted. We apologise for the '
          'inconvenience.',
      'ru': 'Оплата не принимается. Приносим извинения за неудобство.',
    },
  };

  @override
  Widget build(BuildContext context) {
    final notifier = context.watch<AppNotifier>();
    final lang = notifier.lang;

    return Scaffold(
      backgroundColor: const Color(0xFF0A0E1A),
      body: FogBackground(
        accentColor: const Color(0xFFE53935),
        child: SafeArea(
          child: Stack(
            children: [
              Positioned(
                top: 24,
                right: 24,
                child: LangSwitcher(
                  current: lang,
                  onChanged: notifier.setLanguage,
                ),
              ),

              // Невидимая зона долгого нажатия — вход в сервисное меню.
              // Без неё техник не попал бы в меню именно тогда, когда оно
              // нужнее всего (пробный цикл, снятие блокировки).
              Positioned(
                left: 0,
                top: 0,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onLongPress: () => notifier.transition(
                    AppState.servicePinEntry,
                  ),
                  child: const SizedBox(width: 80, height: 80),
                ),
              ),

              Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(PUi.gutter, 112, PUi.gutter, 24),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Container(
                        width: 240,
                        height: 240,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: const Color(0xFFE53935).withValues(alpha: 0.12),
                          border: Border.all(
                            color: const Color(0xFFE53935),
                            width: 4,
                          ),
                        ),
                        child: const Icon(
                          Icons.build_circle_outlined,
                          color: Color(0xFFE53935),
                          size: 144,
                        ),
                      ),
                      const SizedBox(height: 48),
                      Text(
                        _texts['title']![lang] ?? _texts['title']!['ru']!,
                        style: const TextStyle(
                          color: Color(0xFFE53935),
                          fontSize: 44,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 0.5,
                        ),
                        textAlign: TextAlign.center,
                      ),
                      const SizedBox(height: 24),
                      Text(
                        _texts['detail']![lang] ?? _texts['detail']!['ru']!,
                        style: const TextStyle(
                          color: Color(0xFF8899AA),
                          fontSize: PUi.bodySp + 2,
                          height: 1.5,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
