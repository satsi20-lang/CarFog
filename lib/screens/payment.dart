import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/app_state.dart';
import '../services/modbus_service.dart';
import '../services/session_service.dart';
import '../widgets/fog_background.dart';
import '../widgets/lang_switcher.dart';

const Map<String, Map<String, String>> _i18n = {
  'ru': {
    'title': 'ОПЛАТА',
    'flavor': 'Аромат',
    'price': 'Стоимость услуги',
    'paid': 'Внесено',
    'remaining': 'Осталось',
    'instruction': 'Внесите монеты',
    'instruction_with_card': 'Внесите монеты или приложите карту',
    'cancel': 'Отмена',
  },
  'en': {
    'title': 'PAYMENT',
    'flavor': 'Fragrance',
    'price': 'Service price',
    'paid': 'Paid',
    'remaining': 'Remaining',
    'instruction': 'Insert coins',
    'instruction_with_card': 'Insert coins or tap your card',
    'cancel': 'Cancel',
  },
  'et': {
    'title': 'MAKSE',
    'flavor': 'Lõhn',
    'price': 'Teenuse hind',
    'paid': 'Makstud',
    'remaining': 'Jäänud',
    'instruction': 'Lisa münte',
    'instruction_with_card': 'Lisa münte või kasuta kaarti',
    'cancel': 'Tühista',
  },
};

class PaymentScreen extends StatefulWidget {
  const PaymentScreen({super.key});

  @override
  State<PaymentScreen> createState() => _PaymentScreenState();
}

class _PaymentScreenState extends State<PaymentScreen> {
  int _priceCents = 200;
  int _balanceCents = 0;
  int _secondsLeft = 120;

  Timer? _coinTimer;
  Timer? _countdownTimer;
  Timer? _terminalTimer;
  bool _terminalEnabled = false;

  @override
  void initState() {
    super.initState();
    final cfg = context.read<AppNotifier>().config;
    _priceCents = cfg.treatmentPriceCents;
    ModbusService.startPaymentCoinCounting();
    _coinTimer = Timer.periodic(
      const Duration(milliseconds: 100),
      (_) => _checkCoin(),
    );
    _countdownTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _tickCountdown(),
    );

    // Терминал слушаем параллельно с монетоприёмником, только если техник
    // включил его в настройках (Шаг "терминал", задача 4.1/4.6) — пока не
    // подключён физически, вход в принципе ничего не значит.
    _terminalEnabled = cfg.paymentTerminalEnabled;
    if (_terminalEnabled) {
      _terminalTimer = Timer.periodic(
        const Duration(milliseconds: 100),
        (_) => _checkTerminal(cfg),
      );
    }
  }

  @override
  void dispose() {
    _coinTimer?.cancel();
    _countdownTimer?.cancel();
    _terminalTimer?.cancel();
    ModbusService.stopPaymentCoinCounting();
    super.dispose();
  }

  Future<void> _checkCoin() async {
    final cents = await ModbusService.getLastCoinCents();
    if (cents > 0 && mounted) {
      setState(() => _balanceCents += cents);
    }
    if (_balanceCents >= _priceCents) {
      _proceedToTreatment(paymentMethod: 'coins');
    }
  }

  // Терминал настроен эквайером на фиксированную сумму, равную цене
  // обработки — сигнал означает "оплачено полностью", независимо от того,
  // сколько уже внесено монетами (Шаг "терминал", задача 4.2). Если
  // что-то уже накопилось — это переплата, фиксируем отдельным способом
  // оплаты 'mixed', чтобы сумма монет не потерялась в отчётности
  // (задача 4.3).
  Future<void> _checkTerminal(AppConfig cfg) async {
    final poll = await ModbusService.pollTerminal(
      channel: cfg.paymentTerminalChannel,
      mode: cfg.paymentTerminalMode,
      guardMs: cfg.paymentTerminalGuardMs,
    );
    if (poll != null && poll.confirmed) {
      _proceedToTreatment(
        paymentMethod: _balanceCents > 0 ? 'mixed' : 'card',
        coinsCents: _balanceCents > 0 ? _balanceCents : null,
      );
    }
  }

  void _tickCountdown() {
    setState(() => _secondsLeft--);
    if (_secondsLeft <= 0) {
      _cancel();
    }
  }

  void _proceedToTreatment({
    required String paymentMethod,
    int? coinsCents,
  }) {
    _coinTimer?.cancel();
    _countdownTimer?.cancel();
    _terminalTimer?.cancel();
    ModbusService.stopPaymentCoinCounting();
    if (!mounted) return;
    final notifier = context.read<AppNotifier>();
    final flavorIndex = notifier.selectedFlavor ?? 0;
    // Оплата картой всегда идёт на полную цену (так настроен терминал) —
    // если до этого уже были внесены монеты, они добавляются поверх, а не
    // вычитаются: клиент фактически переплатил (задача 4.3).
    final paidCents = paymentMethod == 'coins'
        ? _balanceCents
        : _priceCents + (coinsCents ?? 0);
    // Начинаем сессию (Шаг 33, задача 1/2) именно здесь — сумма уже
    // набрана, деньги приняты монетоприёмником/терминалом безвозвратно.
    // Название аромата берём по-русски независимо от языка интерфейса
    // клиента: событие уходит оператору, не клиенту.
    unawaited(
      SessionService.start(
        flavorIndex: flavorIndex,
        flavorNameRu: notifier.config.flavorNames['ru']![flavorIndex],
        priceCents: _priceCents,
        paidCents: paidCents,
        paymentMethod: paymentMethod,
        coinsCents: coinsCents,
      ),
    );
    notifier.transition(AppState.preparing);
  }

  void _cancel() {
    _coinTimer?.cancel();
    _countdownTimer?.cancel();
    _terminalTimer?.cancel();
    ModbusService.stopPaymentCoinCounting();
    if (mounted) {
      context.read<AppNotifier>().resetSession();
    }
  }

  String _formatTime(int seconds) {
    final s = seconds < 0 ? 0 : seconds;
    final m = s ~/ 60;
    final r = s % 60;
    return '$m:${r.toString().padLeft(2, '0')}';
  }

  String _euro(int cents) => (cents / 100).toStringAsFixed(2);

  @override
  Widget build(BuildContext context) {
    final notifier = context.watch<AppNotifier>();
    final lang = notifier.lang;
    final t = _i18n[lang]!;
    final flavorIndex = notifier.selectedFlavor ?? 0;
    final flavorName = notifier.config.flavorNames[lang]![flavorIndex];
    final remainingCents = (_priceCents - _balanceCents).clamp(0, _priceCents);
    final progress = _priceCents == 0
        ? 0.0
        : (_balanceCents / _priceCents).clamp(0.0, 1.0);

    return Scaffold(
      backgroundColor: const Color(0xFF1A1A1A),
      body: FogBackground(
        child: SafeArea(
          child: Row(
            children: [
              // Левая колонка: заголовок, аромат, крупная цена
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              t['title']!,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 22,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                          LangSwitcher(
                            current: lang,
                            onChanged: notifier.setLanguage,
                          ),
                        ],
                      ),
                      const SizedBox(height: 24),
                      Text(
                        t['flavor']!,
                        style: const TextStyle(
                          color: Colors.white60,
                          fontSize: 15,
                        ),
                      ),
                      Text(
                        flavorName,
                        style: const TextStyle(
                          color: Color(0xFF2EC4B6),
                          fontSize: 22,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const Spacer(),
                      Text(
                        '${_euro(_priceCents)} €',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 64,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      Text(
                        t['price']!,
                        style: const TextStyle(
                          color: Colors.white60,
                          fontSize: 15,
                        ),
                      ),
                      const Spacer(),
                      Text(
                        _formatTime(_secondsLeft),
                        style: const TextStyle(
                          color: Colors.white38,
                          fontSize: 24,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              // Разделитель
              Container(width: 1, color: const Color(0xFF2E2E2E)),

              // Правая колонка: прогресс, суммы, инструкция, отмена
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        _terminalEnabled
                            ? t['instruction_with_card']!
                            : t['instruction']!,
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 18,
                        ),
                      ),
                      const SizedBox(height: 28),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(10),
                        child: LinearProgressIndicator(
                          value: progress,
                          minHeight: 24,
                          backgroundColor: const Color(0xFF2E2E2E),
                          valueColor: const AlwaysStoppedAnimation<Color>(
                            Color(0xFF2EC4B6),
                          ),
                        ),
                      ),
                      const SizedBox(height: 24),
                      _InfoRow(
                        label: t['paid']!,
                        value: '${_euro(_balanceCents)} €',
                        valueColor: _balanceCents >= _priceCents
                            ? Colors.greenAccent
                            : const Color(0xFF2EC4B6),
                      ),
                      const SizedBox(height: 10),
                      _InfoRow(
                        label: t['remaining']!,
                        value: '${_euro(remainingCents)} €',
                      ),
                      const Spacer(),
                      SizedBox(
                        width: double.infinity,
                        height: 52,
                        child: OutlinedButton(
                          onPressed: _cancel,
                          style: OutlinedButton.styleFrom(
                            foregroundColor: Colors.white60,
                            side: const BorderSide(color: Colors.white30),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8),
                            ),
                          ),
                          child: Text(
                            t['cancel']!,
                            style: const TextStyle(fontSize: 16),
                          ),
                        ),
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

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;
  final Color valueColor;

  const _InfoRow({
    required this.label,
    required this.value,
    this.valueColor = Colors.white,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: const TextStyle(color: Colors.white60, fontSize: 15),
        ),
        Text(
          value,
          style: TextStyle(
            color: valueColor,
            fontSize: 15,
            fontWeight: FontWeight.bold,
          ),
        ),
      ],
    );
  }
}
