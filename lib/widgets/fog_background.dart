import 'dart:math' as math;
import 'package:flutter/material.dart';

// Фон клиентских экранов: вертикальный градиент базовых тёмных тонов темы
// + несколько крупных, медленно плывущих пятен дымки, подсвеченных
// цветом-акцентом текущего экрана. Заставку (там играет видео) и
// сервисное меню (там важна плотность информации, не атмосфера) этим
// виджетом не оборачиваем — см. комментарии в screens/, где он подключён.
class FogBackground extends StatefulWidget {
  // Чем подсвечена дымка — красный на экране ошибки, тёплый на подготовке,
  // бирюза (значение по умолчанию) на остальных клиентских экранах.
  final Color accentColor;

  // 0..1 — насколько заметна дымка. По умолчанию низкая: дымка должна
  // угадываться, а не заслонять текст. 0 полностью гасит пятна, оставляя
  // (если paintBase остался true) только базовый градиент — так
  // treating.dart отключает дымку на время финального мигания, которое
  // важнее (см. подключение в treating.dart).
  final double intensity;

  // false — дымка застывает на месте (AnimationController не крутится).
  // Разовый выключатель на случай, если на месте выяснится, что анимация
  // мешает работе аппарата.
  final bool animated;

  // false — не заливать базовый градиент, рисовать только пятна поверх
  // того, что уже нарисовано ниже. Нужно там, где фон экрана и так живёт
  // своей жизнью (мигающий Scaffold.backgroundColor на treating.dart) —
  // не дублировать и не перекрывать его собственной заливкой.
  final bool paintBase;

  final Widget child;

  FogBackground({
    super.key,
    this.accentColor = const Color(0xFF2EC4B6),
    this.intensity = 0.16,
    this.animated = true,
    this.paintBase = true,
    required this.child,
  });

  @override
  State<FogBackground> createState() => _FogBackgroundState();
}

class _FogBackgroundState extends State<FogBackground>
    with SingleTickerProviderStateMixin {
  // Полный цикл дыхания — не меньше 40 сек, иначе плавающие пятна
  // читаются как суета, а не спокойная дымка.
  static const _cycle = Duration(seconds: 48);

  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: _cycle);
    if (widget.animated) {
      _controller.repeat();
    }
  }

  @override
  void didUpdateWidget(covariant FogBackground oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.animated && !_controller.isAnimating) {
      _controller.repeat();
    } else if (!widget.animated && _controller.isAnimating) {
      _controller.stop();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        if (widget.paintBase) const _FogBaseGradient(),
        if (widget.intensity > 0)
          // RepaintBoundary + CustomPainter(repaint: controller) —
          // каждый тик анимации перерисовывает только сам туман, не
          // трогая дерево виджетов над ним (в том числе текст и таймеры
          // на экране подготовки/обработки).
          RepaintBoundary(
            child: CustomPaint(
              painter: _FogPainter(
                animation: _controller,
                color: widget.accentColor,
                intensity: widget.intensity,
              ),
              size: Size.infinite,
            ),
          ),
        widget.child,
      ],
    );
  }
}

class _FogBaseGradient extends StatelessWidget {
  const _FogBaseGradient();

  @override
  Widget build(BuildContext context) {
    return const DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          // Глубокий графит темы (#0A0E1A) → базовый фон приложения,
          // чуть светлее (#1A1A1A) — оба уже используются в проекте,
          // новых оттенков не вводим.
          colors: [Color(0xFF0A0E1A), Color(0xFF1A1A1A)],
        ),
      ),
    );
  }
}

class _Blob {
  final double dx, dy; // базовый центр, доля ширины/высоты (0..1)
  final double orbit; // на сколько долей размера пятно уходит от центра
  final double radius; // радиус пятна, доля меньшей стороны экрана
  final double freqX, freqY; // независимые частоты по осям — путь не круг,
                              // а более органичная плывущая траектория
  final double phase;
  final double alphaScale; // множитель к intensity — не все пятна
                            // одинаково яркие, иначе дымка выглядит как
                            // регулярная решётка, а не туман

  const _Blob(this.dx, this.dy, this.orbit, this.radius, this.freqX,
      this.freqY, this.phase, this.alphaScale);
}

// Пять крупных мягких пятен вместо системы частиц — дешевле на этом
// железе и на глаз убедительнее как туман. Координаты подобраны так,
// чтобы пятна в среднем покрывали весь экран, а не собирались в углу.
const _blobs = [
  _Blob(0.18, 0.22, 0.10, 0.55, 0.8, 1.1, 0.0, 0.9),
  _Blob(0.82, 0.18, 0.12, 0.48, 1.1, 0.7, 1.7, 0.7),
  _Blob(0.30, 0.78, 0.09, 0.60, 0.9, 1.3, 3.1, 0.8),
  _Blob(0.85, 0.75, 0.11, 0.50, 1.2, 0.9, 4.6, 0.6),
  _Blob(0.55, 0.45, 0.08, 0.65, 0.7, 1.0, 2.2, 0.5),
];

// Не BackdropFilter/размытие изображений (дорого на RK3568) — мягкость
// краёв даёт RadialGradient-шейдер, который считает GPU. repaint:
// animation в конструкторе CustomPainter — Flutter перерисовывает только
// canvas этого painter'а на каждый тик, без пересборки виджетов.
class _FogPainter extends CustomPainter {
  final Animation<double> animation;
  final Color color;
  final double intensity;

  _FogPainter({
    required this.animation,
    required this.color,
    required this.intensity,
  }) : super(repaint: animation);

  @override
  void paint(Canvas canvas, Size size) {
    final t = animation.value * 2 * math.pi;
    final shortSide = math.min(size.width, size.height);

    for (final blob in _blobs) {
      final cx =
          (blob.dx + blob.orbit * math.sin(t * blob.freqX + blob.phase)) *
              size.width;
      final cy =
          (blob.dy + blob.orbit * math.cos(t * blob.freqY + blob.phase)) *
              size.height;
      final r = blob.radius * shortSide;
      final alpha = intensity * blob.alphaScale;

      final paint = Paint()
        ..shader = RadialGradient(
          colors: [
            color.withValues(alpha: alpha),
            color.withValues(alpha: 0),
          ],
        ).createShader(Rect.fromCircle(center: Offset(cx, cy), radius: r));

      canvas.drawCircle(Offset(cx, cy), r, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _FogPainter oldDelegate) {
    return oldDelegate.color != color || oldDelegate.intensity != intensity;
  }
}
