import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:provider/provider.dart';

import '../../models/app_state.dart';
import '../../services/mdb_bench_service.dart';
import '../../widgets/portrait_ui.dart';

// Вкладка «Терминал (стенд)» сервисного меню (1.10.9): ручная проверка
// терминала Nayax по MDB через USB-адаптер Wafer MDB-RS232. Ничего не шлёт
// без нажатия кнопки, к боевой оплате и шине Modbus не подключена.
// Только русский язык — временный инструмент наладчика. Порядок проверки и
// ограничения — docs/payment_mdb_bench.md.

class MdbBenchTab extends StatefulWidget {
  const MdbBenchTab({super.key});

  @override
  State<MdbBenchTab> createState() => _MdbBenchTabState();
}

class _MdbBenchTabState extends State<MdbBenchTab> {
  static const _bg = Color(0xFF111827);
  static const _dim = Color(0xFF8899AA);
  static const _red = Color(0xFFE5484D);
  static const _maxLines = 2000;

  static const _drivers = {
    'auto': 'авто',
    'ftdi': 'FTDI',
    'ch34x': 'CH34x',
    'cp21xx': 'CP210x',
    'prolific': 'PL2303',
    'cdc': 'CDC ACM',
  };

  // vend отправлен, итога списания нет (1.11.2): нейтрально, без «исход
  // неизвестен». Язык меню обслуживания — ru/en/et, как у других вкладок.
  static const _vendUnsettled = {
    'ru': 'Терминал не сообщил итог списания — сверьте операцию в кабинете Nayax.',
    'en': 'The terminal did not report the final charge status — check the transaction in the Nayax portal.',
    'et': 'Terminal ei teatanud makse lõpptulemust — kontrollige tehingut Nayaxi portaalis.',
  };

  // Язык меню; вкладка без AppNotifier (отдельный тест) — русский.
  static String _lang(BuildContext context) {
    try {
      return Provider.of<AppNotifier>(context, listen: false).serviceLang;
    } on ProviderNotFoundException {
      return 'ru';
    }
  }

  final _amount = TextEditingController(text: '0.10');
  final _raw = TextEditingController();
  // Задержка теста А перед 13 02.
  int _delaySec = 30;
  final _lines = <String>[];
  int _lastSeq = 0;
  Timer? _poll;
  bool _polling = false;

  List<MdbUsbDevice> _devices = const [];
  String? _selected;
  String _driver = 'auto';
  MdbBenchStatus _status = const MdbBenchStatus();
  String? _message;
  bool _messageIsError = false;
  String? _rawError;

  @override
  void initState() {
    super.initState();
    // Пока вкладка открыта, порт у стенда, а не у оплаты картой (ТЗ 7.2).
    MdbBenchService.enterService().catchError((_) {});
    _refresh();
    _poll = Timer.periodic(
      const Duration(milliseconds: 250),
      (_) => _refresh(),
    );
  }

  @override
  void dispose() {
    // Порт стенда закрывается и возвращается оплате картой.
    MdbBenchService.exitService().catchError((_) {});
    _poll?.cancel();
    _amount.dispose();
    _raw.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    if (_polling) return;
    _polling = true;
    try {
      final fresh = await MdbBenchService.getLog(_lastSeq);
      final status = await MdbBenchService.status();
      if (!mounted) return;
      setState(() {
        for (final e in fresh) {
          _lines.add(e.line);
          _lastSeq = e.seq;
        }
        if (_lines.length > _maxLines) {
          _lines.removeRange(0, _lines.length - _maxLines);
        }
        _status = status;
      });
    } catch (_) {
      // Канала нет (тесты) или Kotlin занят — следующий тик повторит.
    } finally {
      _polling = false;
    }
  }

  void _say(String text, {bool error = false}) {
    if (!mounted) return;
    setState(() {
      _message = text;
      _messageIsError = error;
    });
  }

  Future<void> _run(Future<void> Function() action) async {
    try {
      await action();
    } on PlatformException catch (e) {
      _say(e.message ?? e.code, error: true);
    } catch (e) {
      _say('$e', error: true);
    }
    await _refresh();
  }

  Future<void> _find() => _run(() async {
    final list = await MdbBenchService.listDevices();
    setState(() {
      _devices = list;
      if (!list.any((d) => d.device == _selected)) {
        _selected = list.isEmpty ? null : list.first.device;
      }
    });
    _say(
      list.isEmpty
          ? 'USB-устройств не найдено. Адаптер подключён? Режим OTG не менять.'
          : 'Найдено устройств: ${list.length}',
    );
  });

  Future<void> _open() => _run(() async {
    final dev = _selected;
    if (dev == null) {
      _say('Сначала найдите и выберите устройство', error: true);
      return;
    }
    final r = await MdbBenchService.open(dev, driver: _driver);
    _say(
      r == 'permission_requested'
          ? 'Запрошено разрешение на USB. Подтвердите в системном окне — '
                'порт откроется сам. Если окна нет, см. журнал и '
                'docs/payment_mdb_bench.md.'
          : 'Порт открыт',
    );
  });

  Future<void> _close() => _run(() async {
    await MdbBenchService.close();
    _say('Порт закрыт');
  });

  Future<void> _command(String name) => _run(() async {
    final hex = await MdbBenchService.command(name);
    _say('В очереди $name: $hex (уходит после ACK предыдущей команды)');
  });

  Future<void> _vend() => _run(() async {
    if (!_status.hasSetup) {
      _say(
        'Нет ответа на setup: сначала setup и дождитесь ответа '
        '(масштаб и знаки нужны для суммы).',
        error: true,
      );
      return;
    }
    // Сумму считает стенд — в окне то, что уйдёт в адаптер.
    final p = await MdbBenchService.vendPreview(_amount.text.trim());
    if (!mounted) return;
    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: _bg,
        title: Text(
          'Списать ${p.amount} € с карты? Это реальная оплата.',
          style: const TextStyle(color: Colors.white, fontSize: 20),
        ),
        content: Text(
          '${p.units} ед. терминала (масштаб ${p.scale}, знаков ${p.decimals})\n'
          'Байты: ${p.hex}',
          style: const TextStyle(color: _dim, fontSize: 16),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Отмена', style: TextStyle(fontSize: 18)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text(
              'Списать',
              style: TextStyle(
                color: _red,
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );
    if (ok != true) {
      _say('Запрос оплаты отменён, ничего не отправлено');
      return;
    }
    final hex = await MdbBenchService.sendVend(p);
    _say('Запрос оплаты ${p.amount} € в очереди: $hex');
  });

  Future<void> _testStart() => _startTest(
    mode: 'normal',
    title: 'Тестовая оплата',
    details:
        'Это реальная оплата: setup, prices, enable, затем приложите '
        'карту в течение 60 с. Сумма 10 ед. (0,10 €), один раз.',
  );

  Future<void> _testDelay() => _startTest(
    mode: 'delay',
    delaySec: _delaySec,
    title: 'Тест А (задержка $_delaySec с)',
    details:
        'Реальная оплата 0,10 €. После одобрения (10 05) стенд $_delaySec с '
        'не отвечает терминалу, затем 13 02 и 13 04. Смотрим, что терминал '
        'делает сам.',
  );

  Future<void> _testRefund() => _startTest(
    mode: 'refund',
    title: 'Тест Б (возврат)',
    details:
        'Реальная оплата 0,10 €. После одобрения (10 05) через 1 с стенд '
        'шлёт 13 03 (ошибка выдачи — возврат), затем 13 04. После теста '
        'проверьте списание на карте.',
  );

  Future<void> _startTest({
    required String mode,
    required String title,
    required String details,
    int delaySec = 0,
  }) => _run(() async {
    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: _bg,
        title: const Text(
          'Будет списано 0,10 € с карты',
          style: TextStyle(color: Colors.white, fontSize: 20),
        ),
        content: Text(
          details,
          style: const TextStyle(color: _dim, fontSize: 16),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Отмена', style: TextStyle(fontSize: 18)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text(
              'Списать',
              style: TextStyle(
                color: _red,
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );
    if (ok != true) {
      _say('$title отменён(а), ничего не отправлено');
      return;
    }
    await MdbBenchService.testStart(mode: mode, delaySec: delaySec);
    _say('$title запущен(а) — следите за состоянием и журналом');
  });

  Future<void> _testAbort() => _run(() async {
    await MdbBenchService.testAbort();
    _say(
      'Тестовая оплата прерывается (отмена по текущему шагу, затем disable)',
    );
  });

  Future<void> _sendRaw() async {
    final err = MdbBenchService.validateHex(_raw.text);
    setState(() => _rawError = err);
    if (err != null) return;
    await _run(() async {
      final hex = await MdbBenchService.raw(_raw.text);
      _say('В очереди: $hex (уходит после ACK предыдущей команды)');
    });
  }

  Future<void> _copy() => _run(() async {
    final text = await MdbBenchService.allLog();
    await Clipboard.setData(ClipboardData(text: text));
    _say(
      'Журнал скопирован (${text.isEmpty ? 0 : text.split('\n').length} строк)',
    );
  });

  Future<void> _clear() => _run(() async {
    await MdbBenchService.clearLog();
    setState(_lines.clear);
    _say('Экран журнала очищен (файл не тронут)');
  });

  @override
  Widget build(BuildContext context) {
    final s = _status;
    // Ручные команды — только при открытом порте и вне тестовой оплаты.
    final manual = s.open && !s.testActive;
    // Верх закреплён: предупреждение, состояние порта, приёма, тестовой
    // оплаты и ответ на последнее нажатие видны при любой прокрутке.
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: _red.withValues(alpha: 0.15),
                  border: Border.all(color: _red, width: 2),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Text(
                  'Тестовый режим: реальное списание. Стенд не связан с боевой '
                  'оплатой аппарата.',
                  style: TextStyle(
                    color: _red,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              _text(
                'Порт: ${s.open ? 'открыт (${s.device})' : 'закрыт'}   ·   '
                'setup: ${s.hasSetup ? 'масштаб ${s.setupScale}, знаков ${s.setupDecimals}' : 'нет ответа'}',
                bold: true,
              ),
              _text(
                'Приём: ${s.enabled ? 'включён' : 'выключен'}   ·   '
                'сессия: ${s.inSession ? 'идёт' : 'нет'}   ·   '
                'очередь: ${s.queueSize}',
                color: _dim,
              ),
              if (s.sessionWarning != null)
                _text('Внимание: ${s.sessionWarning}', color: _red, bold: true),
              if (s.testActive || s.testOutcome != null) ...[
                const SizedBox(height: 8),
                _text(
                  '${s.testMode ?? 'Тестовая оплата'}: ${s.testState ?? '?'}',
                  bold: true,
                ),
                if (s.holdRemainingMs != null)
                  _text(
                    'До 13 02 осталось ${(s.holdRemainingMs! / 1000).ceil()} с',
                    color: _red,
                    size: 22,
                    bold: true,
                  ),
                // Итог уже начинается с «УСПЕХ — », «НЕ УДАЛАСЬ — » или
                // «возврат запрошен: …».
                if (s.testOutcome != null)
                  _text(
                    s.testOutcome!,
                    color: s.testOutcomeOk == true ? PUi.accent : _red,
                    bold: true,
                  ),
                if (s.testOutcome != null && s.testVendUnsettled)
                  _text(
                    _vendUnsettled[_lang(context)] ?? _vendUnsettled['ru']!,
                    color: _red,
                  ),
              ],
              if (_message != null) ...[
                const SizedBox(height: 8),
                _text(_message!, color: _messageIsError ? _red : PUi.accent),
              ],
            ],
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            children: [
              if (s.open && s.silent && !s.testActive) ...[
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    border: Border.all(color: _red),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _text(
                        'Адаптер не ответил на опрос setup. Автоматически ничего '
                        'не повторяется. Если нужно — заново по порядку:',
                        color: _red,
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final c in const ['setup', 'prices', 'enable'])
                            _button(c, () => _command(c)),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
              if (s.logFile != null)
                _text('Файл журнала: ${s.logFile}', color: _dim, size: 14),
              const SizedBox(height: 16),
              _section('USB-адаптер'),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _button('Найти USB-устройства', _find),
                  _button('Открыть порт', s.open ? null : _open),
                  _button('Закрыть порт', s.open ? _close : null),
                ],
              ),
              const SizedBox(height: 8),
              for (final d in _devices)
                ListTile(
                  onTap: s.open
                      ? null
                      : () => setState(() => _selected = d.device),
                  leading: Icon(
                    d.device == _selected
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked,
                    color: PUi.accent,
                  ),
                  title: _text(d.title),
                  subtitle: _text(
                    '${d.device} · класс ${d.deviceClass} · интерфейсы ${d.interfaceClasses.join(',')}'
                    ' · драйвер ${d.driver ?? 'не найден'}'
                    ' · разрешение ${d.hasPermission ? 'есть' : 'нет'}',
                    color: _dim,
                    size: 14,
                  ),
                ),
              Row(
                children: [
                  _text('Драйвер: '),
                  DropdownButton<String>(
                    value: _driver,
                    dropdownColor: _bg,
                    onChanged: s.open
                        ? null
                        : (v) => setState(() => _driver = v ?? 'auto'),
                    items: [
                      for (final e in _drivers.entries)
                        DropdownMenuItem(value: e.key, child: _text(e.value)),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 16),
              _section('Одна тестовая оплата 0,10 €'),
              _text(
                'Автоматически: setup → prices → enable → ждём карту (10 03) до '
                '60 с → vend 10 ед. → 13 02 + 13 04 → disable. Сумма жёстко '
                '10 ед., повторный vend невозможен.',
                color: _dim,
                size: 14,
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _button(
                    'Тестовая оплата 0,10 €',
                    s.open && !s.testActive ? _testStart : null,
                  ),
                  _button('Прервать', s.testActive ? _testAbort : null),
                ],
              ),
              const SizedBox(height: 16),
              _section('Служебные тесты оплаты'),
              _text(
                'Реальное списание 0,10 € в каждом тесте.',
                color: _red,
                bold: true,
              ),
              _text(
                'Тест А: после одобрения ждём выбранное время без ответов '
                'терминалу, потом 13 02 и 13 04. Тест Б: после одобрения '
                '13 03 (возврат), потом 13 04.',
                color: _dim,
                size: 14,
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  _text('Задержка теста А: '),
                  DropdownButton<int>(
                    value: _delaySec,
                    dropdownColor: _bg,
                    onChanged: s.testActive
                        ? null
                        : (v) => setState(() => _delaySec = v ?? 30),
                    items: [
                      for (final v in const [30, 60, 90, 120])
                        DropdownMenuItem(value: v, child: _text('$v с')),
                    ],
                  ),
                ],
              ),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _button(
                    'Тест А (задержка)',
                    s.open && !s.testActive ? _testDelay : null,
                  ),
                  _button(
                    'Тест Б (возврат)',
                    s.open && !s.testActive ? _testRefund : null,
                  ),
                ],
              ),
              const SizedBox(height: 16),
              _section('Команды MDB'),
              if (s.testActive)
                _text(
                  'Во время тестовой оплаты ручные команды, другие суммы, id и '
                  'raw недоступны.',
                  color: _dim,
                  size: 14,
                ),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final c in const [
                    'setup',
                    'prices',
                    'enable',
                    'disable',
                    'rcancel',
                    'cancel',
                    'vendfail',
                    'done',
                    'ok',
                    'id',
                  ])
                    _button(c, manual ? () => _command(c) : null),
                ],
              ),
              _text(
                'Порядок: setup → prices → enable → приложить карту → '
                'запрос оплаты 0.10 → ok → done',
                color: _dim,
                size: 14,
              ),
              const SizedBox(height: 16),
              _section('Запрос оплаты (vend)'),
              Row(
                children: [
                  SizedBox(width: 160, child: _field(_amount, 'Сумма, €')),
                  const SizedBox(width: 12),
                  _button('Запрос оплаты', manual ? _vend : null),
                ],
              ),
              const SizedBox(height: 16),
              _section('Свои байты (raw)'),
              Row(
                children: [
                  Expanded(
                    child: _field(
                      _raw,
                      'hex, например 14 01',
                      error: _rawError,
                    ),
                  ),
                  const SizedBox(width: 12),
                  _button('Отправить', manual ? _sendRaw : null),
                ],
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(child: _section('Журнал (${_lines.length})')),
                  _button('Копировать журнал', _copy),
                  const SizedBox(width: 8),
                  _button('Очистить', _clear),
                ],
              ),
              Container(
                height: 520,
                margin: const EdgeInsets.only(top: 8),
                padding: const EdgeInsets.all(8),
                color: Colors.black,
                child: ListView.builder(
                  reverse: true,
                  itemCount: _lines.length,
                  itemBuilder: (_, i) => SelectableText(
                    _lines[_lines.length - 1 - i],
                    style: const TextStyle(
                      color: Color(0xFFCCDDEE),
                      fontFamily: 'monospace',
                      fontSize: 12,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _text(
    String t, {
    Color color = Colors.white,
    double size = 16,
    bool bold = false,
  }) => Text(
    t,
    style: TextStyle(
      color: color,
      fontSize: size,
      fontWeight: bold ? FontWeight.bold : FontWeight.normal,
    ),
  );

  Widget _section(String t) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: _text(t, color: PUi.accent, size: 18, bold: true),
  );

  Widget _button(String label, VoidCallback? onPressed) => ElevatedButton(
    onPressed: onPressed,
    style: ElevatedButton.styleFrom(
      minimumSize: const Size(88, PUi.minTouch),
      backgroundColor: const Color(0xFF1F2937),
      foregroundColor: Colors.white,
    ),
    child: Text(label, style: const TextStyle(fontSize: 16)),
  );

  Widget _field(TextEditingController c, String label, {String? error}) =>
      TextField(
        controller: c,
        style: const TextStyle(color: Colors.white, fontSize: 18),
        decoration: InputDecoration(
          labelText: label,
          labelStyle: const TextStyle(color: _dim),
          errorText: error,
          enabledBorder: const OutlineInputBorder(
            borderSide: BorderSide(color: _dim),
          ),
          focusedBorder: const OutlineInputBorder(
            borderSide: BorderSide(color: PUi.accent),
          ),
        ),
      );
}
