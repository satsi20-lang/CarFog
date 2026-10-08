import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/app_state.dart';
import '../widgets/fog_background.dart';
import '../widgets/portrait_ui.dart';
import '../widgets/lang_switcher.dart';

class FinishedScreen extends StatefulWidget {
  const FinishedScreen({super.key});

  @override
  State<FinishedScreen> createState() => _FinishedScreenState();
}

class _FinishedScreenState extends State<FinishedScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _scaleController;
  late Animation<double> _scaleAnimation;
  Timer? _countdownTimer;
  int _secondsLeft = 5;

  static const _labels = {
    'title': {
      'et': 'Töötlus lõpetatud!',
      'en': 'Treatment complete!',
      'ru': 'Обработка завершена!',
    },
    'subtitle': {
      'et': 'Teie auto salon on töödeldud kuiva uduga.',
      'en': 'Your car interior has been treated with dry fog.',
      'ru': 'Салон вашего автомобиля обработан сухим туманом.',
    },
    'returning': {
      'et': 'Naaseb algusesse',
      'en': 'Returning to start',
      'ru': 'Возврат к началу',
    },
    'sec': {'et': 's', 'en': 's', 'ru': 'с'},
  };

  String _t(String key, String lang) => _labels[key]?[lang] ?? '';

  @override
  void initState() {
    super.initState();

    _scaleController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _scaleAnimation = CurvedAnimation(
      parent: _scaleController,
      curve: Curves.elasticOut,
    );
    _scaleController.forward();

    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      setState(() => _secondsLeft--);
      if (_secondsLeft <= 0) {
        timer.cancel();
        context.read<AppNotifier>().resetSession();
      }
    });
  }

  @override
  void dispose() {
    _scaleController.dispose();
    _countdownTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final notifier = context.watch<AppNotifier>();
    final lang = notifier.lang;

    return Scaffold(
      backgroundColor: const Color(0xFF0A0E1A),
      body: FogBackground(
        child: SafeArea(
          child: Stack(
            children: [
              // Lang switcher
              Positioned(
                top: 24,
                right: 24,
                child: LangSwitcher(
                  current: lang,
                  onChanged: notifier.setLanguage,
                ),
              ),

              // Main content
              Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.only(top: 112, bottom: 24),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      // Animated checkmark
                      ScaleTransition(
                        scale: _scaleAnimation,
                        child: Container(
                          width: 240,
                          height: 240,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: const Color(
                              0xFF00C6B2,
                            ).withValues(alpha: 0.15),
                            border: Border.all(
                              color: const Color(0xFF00C6B2),
                              width: 4,
                            ),
                          ),
                          child: const Icon(
                            Icons.check_rounded,
                            color: Color(0xFF00C6B2),
                            size: 144,
                          ),
                        ),
                      ),

                      const SizedBox(height: 48),

                      // Title
                      Text(
                        _t('title', lang),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 48,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 0.5,
                        ),
                        textAlign: TextAlign.center,
                      ),

                      const SizedBox(height: 24),

                      // Subtitle
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: PUi.gutter,
                        ),
                        child: Text(
                          _t('subtitle', lang),
                          style: const TextStyle(
                            color: Color(0xFF8899AA),
                            fontSize: PUi.bodySp + 2,
                            height: 1.5,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ),

                      const SizedBox(height: 64),

                      // Countdown
                      Column(
                        children: [
                          Text(
                            _t('returning', lang),
                            style: const TextStyle(
                              color: Color(0xFF8899AA),
                              fontSize: PUi.minBodySp,
                            ),
                          ),
                          const SizedBox(height: 12),
                          Container(
                            width: 96,
                            height: 96,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: const Color(
                                  0xFF00C6B2,
                                ).withValues(alpha: 0.4),
                                width: 2,
                              ),
                            ),
                            child: Center(
                              child: Text(
                                '$_secondsLeft${_t('sec', lang)}',
                                style: const TextStyle(
                                  color: Color(0xFF00C6B2),
                                  fontSize: 32,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                          ),
                        ],
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
