import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../brand/brand_colors.dart';
import '../models/hardware_profile.dart';

// Размеры портретного макета под Syoung SY156-A510 (15,6", логические
// 720x1280 dp, пользователь стоит в 0,5–1 м). Единый источник: экраны
// клиента не берут «магические» числа сами.
class PUi {
  PUi._();

  // Шрифты (sp): заголовок ≥ 36, основной текст ≥ 22.
  static const double titleSp = 40;
  static const double bodySp = 24;
  static const double minTitleSp = 36;
  static const double minBodySp = 22;

  // Кнопки: высота ≥ 72 dp, зона касания ≥ 56 dp.
  static const double buttonH = 80;
  static const double minButtonH = 72;
  static const double minTouch = 56;

  // Поля по краям.
  static const double gutter = 32;

  // Переключатель языка ET/EN/RU: высота ≥ 64 dp.
  static const double langH = 64;
  static const double langW = 88;

  static const Color accent = Color(0xFF2EC4B6);

  // Размеры профиля этого запуска (константы выше — портретный набор,
  // UiMetrics.portrait; альбомный IXP101M1 — UiMetrics.landscape).
  static UiMetrics get m => HardwareProfile.current.ui;

  // Альбомная раскладка (профиль ixp101m1): экраны выбирают отдельную
  // ветку построения, портретный код не меняется.
  static bool get landscape => HardwareProfile.current.landscape;
}

// Колонка на весь экран: при достаточной высоте Spacer/Expanded внутри
// работают как обычно, а если контент не помещается (самый длинный язык,
// крупный шрифт) — экран прокручивается, а не переполняется.
class PortraitScroll extends StatelessWidget {
  final Widget child;
  const PortraitScroll({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) => SingleChildScrollView(
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: c.maxHeight),
          child: IntrinsicHeight(child: child),
        ),
      ),
    );
  }
}

// Альбомная шапка (IXP101M1): заголовок и подзаголовок слева компактно,
// переключатель языка справа — контент он не перекрывает.
class LandscapeHeader extends StatelessWidget {
  final String title;
  // null — textPrimary бренда.
  final Color? titleColor;
  final String? subtitle;
  final Widget? trailing;

  const LandscapeHeader({
    super.key,
    required this.title,
    this.titleColor,
    this.subtitle,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final m = PUi.m;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: titleColor ?? context.brand.textPrimary,
                  fontSize: m.titleSp,
                  fontWeight: FontWeight.bold,
                  height: 1.2,
                ),
              ),
              if (subtitle != null && subtitle!.isNotEmpty)
                Text(
                  subtitle!,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: context.brand.textPrimaryA(0x99), // white60
                    fontSize: m.minBodySp,
                  ),
                ),
            ],
          ),
        ),
        ?trailing,
      ],
    );
  }
}

// Кнопка «Отмена»/«Назад» альбомных экранов: высота профиля (≥ 56 dp).
class LandscapeCancelButton extends StatelessWidget {
  final String text;
  final VoidCallback? onPressed;
  // null — производные textPrimary бренда (white70 / white38).
  final Color? color;
  final Color? borderColor;

  const LandscapeCancelButton({
    super.key,
    required this.text,
    required this.onPressed,
    this.color,
    this.borderColor,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: PUi.m.buttonH,
      child: OutlinedButton(
        onPressed: onPressed,
        style: OutlinedButton.styleFrom(
          foregroundColor: color ?? context.brand.textPrimaryA(0xB3),
          side: BorderSide(
            color: borderColor ?? context.brand.textPrimaryA(0x62),
            width: 2,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
        ),
        child: Text(
          text,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: PUi.m.bodySp + 2),
        ),
      ),
    );
  }
}

// Запасной вариант для IXP101M1 (профиль с guardSystemBars): пока система
// показывает панель навигации (флаги immersive сброшены, сигнал
// SystemChrome.setSystemUIChangeCallback), интерфейс поднимается на её
// высоту — кнопка «Отмена» не уходит под полоску. Сторож (SystemBarsGuard.kt)
// прячет панель через 1–3 с, и интерфейс опускается обратно. Подключается в
// MaterialApp.builder только для этого профиля.
class SystemBarsLift extends StatelessWidget {
  final Widget child;
  const SystemBarsLift({super.key, required this.child});

  // Панель навигации IXP101M1: 72 px при плотности 240 = 48 dp.
  static const double navBarDp = 48;

  static final ValueNotifier<bool> barsVisible = ValueNotifier(false);

  static void listen() {
    SystemChrome.setSystemUIChangeCallback((visible) async {
      barsVisible.value = visible;
    });
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: barsVisible,
      builder: (context, visible, _) => AnimatedPadding(
        duration: const Duration(milliseconds: 150),
        padding: EdgeInsets.only(bottom: visible ? navBarDp : 0),
        child: child,
      ),
    );
  }
}
