import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../models/app_state.dart';
import '../../widgets/lang_switcher.dart';

class ServicePinScreen extends StatefulWidget {
  const ServicePinScreen({super.key});

  @override
  State<ServicePinScreen> createState() => _ServicePinScreenState();
}

class _ServicePinScreenState extends State<ServicePinScreen>
    with SingleTickerProviderStateMixin {
  String _entered = '';
  static const _maxLen = 4;

  late AnimationController _shakeController;
  late Animation<double> _shakeAnimation;

  @override
  void initState() {
    super.initState();
    _shakeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );
    _shakeAnimation = TweenSequence<double>([
      TweenSequenceItem(tween: Tween(begin: 0, end: -10), weight: 1),
      TweenSequenceItem(tween: Tween(begin: -10, end: 10), weight: 2),
      TweenSequenceItem(tween: Tween(begin: 10, end: -6), weight: 2),
      TweenSequenceItem(tween: Tween(begin: -6, end: 6), weight: 2),
      TweenSequenceItem(tween: Tween(begin: 6, end: 0), weight: 1),
    ]).animate(_shakeController);
  }

  @override
  void dispose() {
    _shakeController.dispose();
    super.dispose();
  }

  void _onDigit(String d) {
    if (_entered.length >= _maxLen) return;
    setState(() => _entered += d);
    if (_entered.length == _maxLen) _checkPin();
  }

  void _onBackspace() {
    if (_entered.isEmpty) return;
    setState(() => _entered = _entered.substring(0, _entered.length - 1));
  }

  void _checkPin() {
    final notifier = context.read<AppNotifier>();
    if (_entered == notifier.config.servicePin) {
      notifier.transition(AppState.serviceMenu);
    } else {
      _shakeController.forward(from: 0).then((_) {
        setState(() => _entered = '');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final notifier = context.watch<AppNotifier>();
    final lang = notifier.lang;

    const labels = {
      'title': {'et': 'Sisesta PIN', 'en': 'Enter PIN', 'ru': 'Введите PIN'},
      'cancel': {'et': 'Tühista', 'en': 'Cancel', 'ru': 'Отмена'},
    };

    return Scaffold(
      backgroundColor: const Color(0xFF0A0E1A),
      body: SafeArea(
        child: Stack(
          children: [
            Positioned(
              top: 16,
              right: 16,
              child: LangSwitcher(current: lang, onChanged: notifier.setLanguage),
            ),
            Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    labels['title']![lang]!,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 32),

                  // Точки PIN
                  AnimatedBuilder(
                    animation: _shakeAnimation,
                    builder: (context, child) => Transform.translate(
                      offset: Offset(_shakeAnimation.value, 0),
                      child: child,
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: List.generate(_maxLen, (i) {
                        final filled = i < _entered.length;
                        return Container(
                          margin: const EdgeInsets.symmetric(horizontal: 10),
                          width: 18,
                          height: 18,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: filled
                                ? const Color(0xFF00C6B2)
                                : Colors.transparent,
                            border: Border.all(
                              color: const Color(0xFF00C6B2),
                              width: 2,
                            ),
                          ),
                        );
                      }),
                    ),
                  ),

                  const SizedBox(height: 40),

                  // Цифровая клавиатура
                  SizedBox(
                    width: 280,
                    child: GridView.count(
                      crossAxisCount: 3,
                      shrinkWrap: true,
                      mainAxisSpacing: 12,
                      crossAxisSpacing: 12,
                      childAspectRatio: 1.4,
                      children: [
                        ...['1', '2', '3', '4', '5', '6', '7', '8', '9'].map(
                          (d) => _DigitButton(label: d, onTap: () => _onDigit(d)),
                        ),
                        const SizedBox.shrink(),
                        _DigitButton(label: '0', onTap: () => _onDigit('0')),
                        _DigitButton(
                          label: '⌫',
                          onTap: _onBackspace,
                          color: const Color(0xFF334455),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 32),

                  // Отмена
                  TextButton(
                    onPressed: () => notifier.transition(AppState.standby),
                    child: Text(
                      labels['cancel']![lang]!,
                      style: const TextStyle(
                        color: Color(0xFF556677),
                        fontSize: 16,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DigitButton extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  final Color color;

  const _DigitButton({
    required this.label,
    required this.onTap,
    this.color = const Color(0xFF1A2233),
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: const Color(0xFF2A3A4A)),
        ),
        child: Center(
          child: Text(
            label,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 22,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      ),
    );
  }
}
