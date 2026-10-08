import 'package:flutter/material.dart';

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
