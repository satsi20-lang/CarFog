import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/app_state.dart';
import '../widgets/lang_switcher.dart';

const Map<String, List<String>> flavorNames = {
  'ru': [
    'Лимон',
    'Вишня',
    'Хвоя',
    'Лаванда',
    'Океан',
    'Кофе',
    'Ваниль',
    'Мята',
  ],
  'en': [
    'Lemon',
    'Cherry',
    'Pine',
    'Lavender',
    'Ocean',
    'Coffee',
    'Vanilla',
    'Mint',
  ],
  'et': [
    'Sidrun',
    'Kirss',
    'Mänd',
    'Lavendel',
    'Ookean',
    'Kohv',
    'Vanilje',
    'Münt',
  ],
};

const Map<String, Map<String, String>> i18n = {
  'ru': {
    'title': 'ОПЛАТА',
    'flavor': 'Аромат',
    'price': 'Стоимость услуги',
    'paid': 'Внесено',
    'instruction': 'Приложите карту к терминалу\nили внесите монеты',
    'simulate': 'ИМИТАЦИЯ ОПЛАТЫ',
    'cancel': 'Отмена',
  },
  'en': {
    'title': 'PAYMENT',
    'flavor': 'Fragrance',
    'price': 'Service price',
    'paid': 'Paid',
    'instruction': 'Tap your card on the terminal\nor insert coins',
    'simulate': 'SIMULATE PAYMENT',
    'cancel': 'Cancel',
  },
  'et': {
    'title': 'MAKSE',
    'flavor': 'Lõhn',
    'price': 'Teenuse hind',
    'paid': 'Makstud',
    'instruction': 'Aseta kaart terminalile\nvõi lisa münte',
    'simulate': 'SIMULEERI MAKSET',
    'cancel': 'Tühista',
  },
};

class PaymentScreen extends StatelessWidget {
  const PaymentScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final notifier = context.watch<AppNotifier>();
    final lang = notifier.lang;
    final t = i18n[lang]!;
    final flavorIndex = notifier.selectedFlavor ?? 0;
    final flavorName = flavorNames[lang]![flavorIndex];
    final price = notifier.config.servicePriceEur;
    final paid = notifier.amountPaid;

    return Scaffold(
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

            const SizedBox(height: 40),

            // Выбранный аромат
            _InfoRow(
              label: t['flavor']!,
              value: flavorName,
              valueColor: const Color(0xFF2EC4B6),
            ),
            const SizedBox(height: 16),

            // Стоимость
            _InfoRow(
              label: t['price']!,
              value: '${price.toStringAsFixed(2)} €',
            ),
            const SizedBox(height: 16),

            // Внесено
            _InfoRow(
              label: t['paid']!,
              value:
                  '${paid.toStringAsFixed(2)} € / ${price.toStringAsFixed(2)} €',
              valueColor: paid >= price ? Colors.greenAccent : Colors.white,
            ),

            const SizedBox(height: 40),

            // Прогресс оплаты
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: LinearProgressIndicator(
                  value: (paid / price).clamp(0.0, 1.0),
                  minHeight: 16,
                  backgroundColor: const Color(0xFF2E2E2E),
                  valueColor: const AlwaysStoppedAnimation<Color>(
                    Color(0xFF2EC4B6),
                  ),
                ),
              ),
            ),

            const SizedBox(height: 40),

            // Инструкция
            Text(
              t['instruction']!,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 16,
                height: 1.6,
              ),
            ),

            const Spacer(),

            // Кнопка имитации оплаты
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: SizedBox(
                width: double.infinity,
                height: 60,
                child: ElevatedButton(
                  onPressed: () {
                    final n = context.read<AppNotifier>();
                    n.addPayment(price);
                    if (n.amountPaid >= price) {
                      n.transition(AppState.preparing);
                    }
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF2EC4B6),
                    foregroundColor: Colors.black,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                    textStyle: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  child: Text(t['simulate']!),
                ),
              ),
            ),

            // Кнопка отмены
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: SizedBox(
                width: double.infinity,
                height: 52,
                child: OutlinedButton(
                  onPressed: () {
                    final n = context.read<AppNotifier>();
                    n.resetPayment();
                    n.transition(AppState.selectFlavor);
                  },
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
