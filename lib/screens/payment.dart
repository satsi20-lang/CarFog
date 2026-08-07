import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/app_state.dart';
import '../services/modbus_service.dart';
import '../widgets/lang_switcher.dart';

const Map<String, Map<String, String>> _i18n = {
  'ru': {
    'title': 'ОПЛАТА',
    'flavor': 'Аромат',
    'price': 'Стоимость услуги',
    'paid': 'Внесено',
    'remaining': 'Осталось',
    'instruction': 'Внесите монеты',
    'cancel': 'Отмена',
  },
  'en': {
    'title': 'PAYMENT',
    'flavor': 'Fragrance',
    'price': 'Service price',
    'paid': 'Paid',
    'remaining': 'Remaining',
    'instruction': 'Insert coins',
    'cancel': 'Cancel',
  },
  'et': {
    'title': 'MAKSE',
    'flavor': 'Lõhn',
    'price': 'Teenuse hind',
    'paid': 'Makstud',
    'remaining': 'Jäänud',
    'instruction': 'Lisa münte',
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

  @override
  void initState() {
    super.initState();
    _priceCents = context.read<AppNotifier>().config.treatmentPriceCents;
    ModbusService.startPaymentCoinCounting();
    _coinTimer = Timer.periodic(const Duration(milliseconds: 100), (_) => _checkCoin());
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (_) => _tickCountdown());
  }

  @override
  void dispose() {
    _coinTimer?.cancel();
    _countdownTimer?.cancel();
    ModbusService.stopPaymentCoinCounting();
    super.dispose();
  }

  Future<void> _checkCoin() async {
    final cents = await ModbusService.getLastCoinCents();
    if (cents > 0 && mounted) {
      setState(() => _balanceCents += cents);
    }
    if (_balanceCents >= _priceCents) {
      _proceedToTreatment();
    }
  }

  void _tickCountdown() {
    setState(() => _secondsLeft--);
    if (_secondsLeft <= 0) {
      _cancel();
    }
  }

  void _proceedToTreatment() {
    _coinTimer?.cancel();
    _countdownTimer?.cancel();
    ModbusService.stopPaymentCoinCounting();
    if (mounted) {
      context.read<AppNotifier>().transition(AppState.preparing);
    }
  }

  void _cancel() {
    _coinTimer?.cancel();
    _countdownTimer?.cancel();
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
    final progress = _priceCents == 0 ? 0.0 : (_balanceCents / _priceCents).clamp(0.0, 1.0);

    return Scaffold(
      backgroundColor: const Color(0xFF1A1A1A),
      body: SafeArea(
        child: Column(
          children: [
            // Заголовок + переключатель языка
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
              child: Row(
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
                  LangSwitcher(current: lang, onChanged: notifier.setLanguage),
                ],
              ),
            ),

            const SizedBox(height: 8),

            _InfoRow(
              label: t['flavor']!,
              value: flavorName,
              valueColor: const Color(0xFF2EC4B6),
            ),

            const Spacer(),

            // Цена — крупно
            Text(
              '${_euro(_priceCents)} €',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 56,
                fontWeight: FontWeight.bold,
              ),
            ),
            Text(
              t['price']!,
              style: const TextStyle(color: Colors.white60, fontSize: 15),
            ),

            const SizedBox(height: 32),

            // Прогресс оплаты
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: ClipRRect(
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
            ),

            const SizedBox(height: 20),

            _InfoRow(
              label: t['paid']!,
              value: '${_euro(_balanceCents)} €',
              valueColor: _balanceCents >= _priceCents
                  ? Colors.greenAccent
                  : const Color(0xFF2EC4B6),
            ),
            const SizedBox(height: 8),
            _InfoRow(
              label: t['remaining']!,
              value: '${_euro(remainingCents)} €',
            ),

            const SizedBox(height: 32),

            Text(
              t['instruction']!,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70, fontSize: 16),
            ),

            const Spacer(),

            // Обратный отсчёт
            Text(
              _formatTime(_secondsLeft),
              style: const TextStyle(
                color: Colors.white38,
                fontSize: 28,
                fontWeight: FontWeight.bold,
              ),
            ),

            const SizedBox(height: 24),

            // Кнопка отмены
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: SizedBox(
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
            ),
          ],
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
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Row(
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
      ),
    );
  }
}
