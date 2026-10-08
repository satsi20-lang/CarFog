import 'package:flutter/material.dart';

// Горизонтальная прокрутка с видимой подсказкой: на краю, куда ещё можно
// листать, появляется затухание фона со стрелкой (нажатие листает на ~250 dp).
// Логику содержимого не трогает — просто оборачивает ряд вкладок.
class ScrollHintRow extends StatefulWidget {
  final Widget child;
  final Color background;
  const ScrollHintRow({
    super.key,
    required this.child,
    this.background = const Color(0xFF0A0E1A),
  });

  @override
  State<ScrollHintRow> createState() => _ScrollHintRowState();
}

class _ScrollHintRowState extends State<ScrollHintRow> {
  final _controller = ScrollController();
  bool _canLeft = false;
  bool _canRight = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_update);
  }

  @override
  void dispose() {
    _controller.removeListener(_update);
    _controller.dispose();
    super.dispose();
  }

  void _update() {
    if (!_controller.hasClients || !_controller.position.hasContentDimensions) {
      return;
    }
    final p = _controller.position;
    final left = p.pixels > 1;
    final right = p.pixels < p.maxScrollExtent - 1;
    if (left != _canLeft || right != _canRight) {
      setState(() {
        _canLeft = left;
        _canRight = right;
      });
    }
  }

  void _by(double delta) {
    final p = _controller.position;
    _controller.animateTo(
      (p.pixels + delta).clamp(0.0, p.maxScrollExtent),
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
    );
  }

  Widget _edge({required bool left}) {
    final bg = widget.background;
    return Positioned(
      top: 0,
      bottom: 0,
      left: left ? 0 : null,
      right: left ? null : 0,
      width: 64,
      child: GestureDetector(
        key: ValueKey(left ? 'tabs_hint_left' : 'tabs_hint_right'),
        behavior: HitTestBehavior.opaque,
        onTap: () => _by(left ? -250 : 250),
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: left ? Alignment.centerLeft : Alignment.centerRight,
              end: left ? Alignment.centerRight : Alignment.centerLeft,
              colors: [bg, bg.withValues(alpha: 0)],
              stops: const [0.4, 1],
            ),
          ),
          child: Align(
            alignment: left ? Alignment.centerLeft : Alignment.centerRight,
            child: Icon(
              left ? Icons.chevron_left : Icons.chevron_right,
              color: const Color(0xFF00C6B2),
              size: 40,
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Размеры известны только после раскладки: проверяем после каждого кадра
    // сборки (setState только при изменении, цикла нет).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _update();
    });
    return NotificationListener<ScrollMetricsNotification>(
      onNotification: (_) {
        // Размеры известны после раскладки: пересчитать стрелки.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _update();
        });
        return false;
      },
      child: Stack(
        children: [
          SingleChildScrollView(
            controller: _controller,
            scrollDirection: Axis.horizontal,
            child: widget.child,
          ),
          if (_canLeft) _edge(left: true),
          if (_canRight) _edge(left: false),
        ],
      ),
    );
  }
}
