import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/app_state.dart';
import '../../services/card_payment_store.dart';
import '../../services/card_terminal_service.dart';
import '../../widgets/portrait_ui.dart';

// Вкладка «Карта» сервисного меню (1.11.0, ТЗ раздел 9.5): статус терминала
// Nayax по MDB — подключён ли, связь, последние события, незакрытая оплата и
// последние оплаты картой. Только просмотр: настройки — на вкладках
// «Настройки» (цены по запахам, окно возврата) и «Датчики» (тип терминала).
// Данных карты нет (по MDB они не передаются).

const Map<String, Map<String, String>> _i18n = {
  'ru': {
    'type': 'Тип терминала',
    'type_off': 'нет',
    'type_pulse': 'импульсный (DI)',
    'type_mdb': 'карта (MDB)',
    'not_mdb':
        'Оплата картой по MDB выключена. Тип терминала выбирается на вкладке «Датчики».',
    'state': 'Состояние',
    'reader': 'Приём карт',
    'on': 'включён',
    'off': 'выключен',
    'session': 'Сессия на терминале',
    'yes': 'да',
    'no': 'нет',
    'failures': 'Неудач связи подряд',
    'unexpected': 'Неожиданных кадров',
    'payment': 'Оплата',
    'recovery': 'Ждёт возврата после перезапуска',
    'pending': 'Незакрытая оплата картой',
    'none': 'нет',
    'events': 'Последние события',
    'history': 'Последние оплаты картой',
    'settings_hint':
        'Цены по запахам и окно возврата — вкладка «Настройки», тип терминала — «Датчики».',
    'st_success': 'успех',
    'st_refunded': 'возврат',
    'st_manual_refund_needed': 'нужен ручной возврат',
    'st_pending': 'не закрыта',
  },
  'en': {
    'type': 'Terminal type',
    'type_off': 'none',
    'type_pulse': 'pulse (DI)',
    'type_mdb': 'card (MDB)',
    'not_mdb':
        'MDB card payment is off. The terminal type is set on the “Sensors” tab.',
    'state': 'State',
    'reader': 'Card reader',
    'on': 'enabled',
    'off': 'disabled',
    'session': 'Terminal session',
    'yes': 'yes',
    'no': 'no',
    'failures': 'Link failures in a row',
    'unexpected': 'Unexpected frames',
    'payment': 'Payment',
    'recovery': 'Refund pending after restart',
    'pending': 'Unclosed card payment',
    'none': 'none',
    'events': 'Recent events',
    'history': 'Recent card payments',
    'settings_hint':
        'Prices per flavour and refund window — “Settings” tab, terminal type — “Sensors”.',
    'st_success': 'success',
    'st_refunded': 'refunded',
    'st_manual_refund_needed': 'manual refund needed',
    'st_pending': 'not closed',
  },
  'et': {
    'type': 'Terminali tüüp',
    'type_off': 'puudub',
    'type_pulse': 'impulss (DI)',
    'type_mdb': 'kaart (MDB)',
    'not_mdb':
        'MDB kaardimakse on välja lülitatud. Terminali tüüp valitakse vahekaardil «Andurid».',
    'state': 'Olek',
    'reader': 'Kaardilugeja',
    'on': 'sees',
    'off': 'väljas',
    'session': 'Terminali seanss',
    'yes': 'jah',
    'no': 'ei',
    'failures': 'Ühenduse tõrkeid järjest',
    'unexpected': 'Ootamatuid kaadreid',
    'payment': 'Makse',
    'recovery': 'Ootab tagastust pärast taaskäivitust',
    'pending': 'Lõpetamata kaardimakse',
    'none': 'puudub',
    'events': 'Viimased sündmused',
    'history': 'Viimased kaardimaksed',
    'settings_hint':
        'Hinnad lõhnade kaupa ja tagastuse aken — vahekaart «Seaded», terminali tüüp — «Andurid».',
    'st_success': 'õnnestus',
    'st_refunded': 'tagastatud',
    'st_manual_refund_needed': 'vaja käsitsi tagastust',
    'st_pending': 'lõpetamata',
  },
};

class CardStatusTab extends StatefulWidget {
  const CardStatusTab({super.key});

  @override
  State<CardStatusTab> createState() => _CardStatusTabState();
}

class _CardStatusTabState extends State<CardStatusTab> {
  static const _dim = Color(0xFF8899AA);
  static const _warn = Color(0xFFFFB020);
  Timer? _refresh;
  CardPaymentRecord? _pending;
  List<CardPaymentRecord> _history = const [];

  @override
  void initState() {
    super.initState();
    unawaited(_load());
    _refresh = Timer.periodic(const Duration(seconds: 5), (_) => _load());
  }

  @override
  void dispose() {
    _refresh?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final p = await CardPaymentStore.pending();
      final h = await CardPaymentStore.history();
      if (!mounted) return;
      setState(() {
        _pending = p;
        _history = h.reversed.take(10).toList();
      });
    } catch (_) {
      // Нет хранилища (тесты) — показываем, что есть.
    }
  }

  String _time(int ms) {
    final t = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(t.day)}.${two(t.month)} ${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }

  String _euro(int cents) => '${(cents / 100).toStringAsFixed(2)} €';

  @override
  Widget build(BuildContext context) {
    final notifier = context.watch<AppNotifier>();
    final t = _i18n[notifier.serviceLang]!;
    final type = notifier.config.paymentTerminalType;
    return ValueListenableBuilder<CardTerminalStatus>(
      valueListenable: CardTerminalService.status,
      builder: (context, st, _) => ListView(
        padding: const EdgeInsets.all(24),
        children: [
          _row(t['type']!, t['type_$type'] ?? type),
          if (type != PaymentTerminalType.mdb) ...[
            const SizedBox(height: 8),
            _text(t['not_mdb']!, color: _warn),
          ] else ...[
            _row(
              t['state']!,
              st.stateTitle.isEmpty ? st.state : st.stateTitle,
              color: st.cardAvailable ? PUi.accent : _warn,
            ),
            _row(t['reader']!, st.readerEnabled ? t['on']! : t['off']!),
            _row(t['session']!, st.inSession ? t['yes']! : t['no']!),
            _row(t['failures']!, '${st.consecutiveFailures}'),
            _row(t['unexpected']!, '${st.unexpectedFrames}'),
            _row(t['payment']!, st.paymentState),
            _row(
              t['recovery']!,
              st.recoveryPending ? t['yes']! : t['no']!,
              color: st.recoveryPending ? _warn : null,
            ),
          ],
          const SizedBox(height: 16),
          _section(t['pending']!),
          _text(
            _pending == null
                ? t['none']!
                : '${_euro(_pending!.amountCents)} · ${_pending!.flavorName} · ${_time(_pending!.approvedAtMs)}',
            color: _pending == null ? Colors.white : _warn,
            key: const ValueKey('card_pending'),
          ),
          const SizedBox(height: 16),
          _section(t['events']!),
          ValueListenableBuilder<List<String>>(
            valueListenable: CardTerminalService.recent,
            builder: (context, list, _) => list.isEmpty
                ? _text(t['none']!)
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final e in list.reversed)
                        _text(e, size: 13, mono: true),
                    ],
                  ),
          ),
          const SizedBox(height: 16),
          _section(t['history']!),
          if (_history.isEmpty) _text(t['none']!),
          for (final r in _history)
            _text(
              '${_time(r.approvedAtMs)} · ${_euro(r.amountCents)} · ${r.flavorName} · '
              '${t['st_${r.status}'] ?? r.status}',
              color: r.status == 'manual_refund_needed' ? _warn : Colors.white,
              size: 14,
            ),
          const SizedBox(height: 16),
          _text(t['settings_hint']!, color: _dim, size: 13),
        ],
      ),
    );
  }

  Widget _section(String s) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Text(
      s,
      style: const TextStyle(
        color: Color(0xFF556677),
        fontWeight: FontWeight.bold,
        fontSize: 13,
      ),
    ),
  );

  Widget _row(String label, String value, {Color? color}) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(
      children: [
        Expanded(child: _text(label, color: _dim)),
        Flexible(child: _text(value, color: color ?? Colors.white, bold: true)),
      ],
    ),
  );

  Widget _text(
    String s, {
    Color color = Colors.white,
    double size = 16,
    bool bold = false,
    bool mono = false,
    Key? key,
  }) => Text(
    s,
    key: key,
    style: TextStyle(
      color: color,
      fontSize: size,
      fontWeight: bold ? FontWeight.bold : FontWeight.normal,
      fontFamily: mono ? 'monospace' : null,
    ),
  );
}
