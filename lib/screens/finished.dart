import 'dart:async';
import 'package:flutter/material.dart';
import '../brand/brand_colors.dart';
import 'package:provider/provider.dart';
import '../models/app_state.dart';
import '../services/i18n_service.dart';
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

  String _t(
    String key,
    String lang, [
    Map<String, Object?> params = const {},
  ]) => I18n.tr(lang, 'finished.$key', params: params);

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
                top: PUi.landscape ? 12 : 24,
                right: PUi.landscape ? 12 : 24,
                child: LangSwitcher(
                  current: lang,
                  langs: notifier.displayLangs,
                  onChanged: notifier.setLanguage,
                ),
              ),

              // Main content
              if (PUi.landscape)
                _buildLandscape(lang)
              else
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
                              color: context.brand.primaryAlt,
                              width: 4,
                            ),
                          ),
                          child: Icon(
                            Icons.check_rounded,
                            color: context.brand.primaryAlt,
                            size: 144,
                          ),
                        ),
                      ),

                      const SizedBox(height: 48),

                      // Title
                      Text(
                        _t('title', lang),
                        style: TextStyle(
                          color: context.brand.textPrimary,
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
                          style: TextStyle(
                            color: context.brand.textSecondary,
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
                            style: TextStyle(
                              color: context.brand.textSecondary,
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
                                _t('countdown', lang, {
                                  'seconds': _secondsLeft,
                                }),
                                style: TextStyle(
                                  color: context.brand.primaryAlt,
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

  // Альбом 853x533 dp (IXP101M1): галочка слева, текст и отсчёт справа.
  Widget _buildLandscape(String lang) {
    final m = PUi.m;
    return Padding(
      padding: EdgeInsets.fromLTRB(m.gutter + 24, m.langH + 24, m.gutter + 24, 16),
      child: Row(
        children: [
          ScaleTransition(
            scale: _scaleAnimation,
            child: Container(
              width: 168,
              height: 168,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: context.brand.primaryAlt.withValues(alpha: 0.15),
                border: Border.all(color: context.brand.primaryAlt, width: 4),
              ),
              child: Icon(
                Icons.check_rounded,
                color: context.brand.primaryAlt,
                size: 100,
              ),
            ),
          ),
          const SizedBox(width: 40),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _t('title', lang),
                  style: TextStyle(
                    color: context.brand.textPrimary,
                    fontSize: 40,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 0.5,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  _t('subtitle', lang),
                  style: TextStyle(
                    color: context.brand.textSecondary,
                    fontSize: m.bodySp + 2,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 28),
                Row(
                  children: [
                    Container(
                      width: 72,
                      height: 72,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: context.brand.primaryAlt.withValues(alpha: 0.4),
                          width: 2,
                        ),
                      ),
                      child: Center(
                        child: Text(
                          _t('countdown', lang, {'seconds': _secondsLeft}),
                          style: TextStyle(
                            color: context.brand.primaryAlt,
                            fontSize: 28,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Text(
                        _t('returning', lang),
                        style: TextStyle(
                          color: context.brand.textSecondary,
                          fontSize: m.minBodySp,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
