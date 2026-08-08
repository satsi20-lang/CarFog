import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../../models/app_state.dart';
import '../../widgets/lang_switcher.dart';
import '../../services/cloud_service.dart';
import '../../services/modbus_service.dart';

const Map<String, Map<String, String>> _i18n = {
  'ru': {
    'menu_title': 'Сервисное меню',
    'tab_settings': 'Настройки',
    'tab_flavors': 'Ароматы',
    'tab_diagnostics': 'Диагностика',
    'tab_journal': 'Журнал',
    'exit': 'Выход',
    'price_label': 'Цена обработки',
    'duration_label': 'Длительность обработки (сек)',
    'pin_label': 'PIN сервисного меню (4 цифры)',
    'save': 'Сохранить',
    'saved': 'Сохранено',
    'err_price': 'Цена: минимум 0.50 €',
    'err_duration': 'Длительность: 10–120 сек',
    'err_pin': 'PIN — 4 цифры',
    'compressor_purge_label': 'Продувка компрессора до включения насосов и ТЭНа (сек)',
    'pump_after_heater_label': 'Работа насоса после выключения ТЭНа (сек)',
    'err_compressor_purge': 'Продувка компрессора: 1–30 сек',
    'err_pump_after_heater': 'Работа насоса после ТЭНа: 1–30 сек',
    'available': 'Есть',
    'empty_level': 'Пусто',
    'flavor_fallback': 'Аромат',
    'coin_label': 'Монета',
    'coin_yes': 'ДА',
    'coin_no': 'НЕТ',
    'diag_levels': 'Уровни канистр',
    'diag_manual': 'Ручное управление',
    'diag_manual_warning': 'Осторожно: прямое управление оборудованием, минуя обычную логику работы аппарата',
    'pump': 'Насос',
    'compressor': 'Компрессор',
    'heater': 'ТЭН испарителя',
    'all_on': 'Включить всё',
    'all_off': 'Выключить всё',
    'tab_sensors': 'Датчики',
    'sensors_read': 'Читать датчики',
    'sensors_reading': 'Чтение…',
    'sensor_label': 'Датчик',
    'sensor_has_fluid': 'Есть жидкость',
    'sensor_error': 'Ошибка чтения',
    'diag_energy': 'Счётчик энергии',
    'energy_voltage': 'Напряжение',
    'energy_current': 'Ток',
    'energy_power': 'Мощность',
    'refresh': 'Обновить',
    'unit_v': 'В',
    'unit_a': 'А',
    'unit_w': 'Вт',
    'energy_total': 'Общий счётчик',
    'energy_monthly': 'За текущий месяц',
    'energy_previous_month': 'За прошлый месяц',
    'unit_kwh': 'кВт⋅ч',
  },
  'en': {
    'menu_title': 'Service menu',
    'tab_settings': 'Settings',
    'tab_flavors': 'Fragrances',
    'tab_diagnostics': 'Diagnostics',
    'tab_journal': 'Log',
    'exit': 'Exit',
    'price_label': 'Treatment price',
    'duration_label': 'Treatment duration (sec)',
    'pin_label': 'Service menu PIN (4 digits)',
    'save': 'Save',
    'saved': 'Saved',
    'err_price': 'Price: minimum 0.50 €',
    'err_duration': 'Duration: 10–120 sec',
    'err_pin': 'PIN must be 4 digits',
    'compressor_purge_label': 'Compressor purge before pumps/heater turn on (sec)',
    'pump_after_heater_label': 'Pump run time after heater turns off (sec)',
    'err_compressor_purge': 'Compressor purge: 1–30 sec',
    'err_pump_after_heater': 'Pump after heater: 1–30 sec',
    'available': 'OK',
    'empty_level': 'Empty',
    'flavor_fallback': 'Fragrance',
    'coin_label': 'Coin',
    'coin_yes': 'YES',
    'coin_no': 'NO',
    'diag_levels': 'Canister levels',
    'diag_manual': 'Manual control',
    'diag_manual_warning': 'Caution: direct hardware control, bypassing normal machine logic',
    'pump': 'Pump',
    'compressor': 'Compressor',
    'heater': 'Evaporator heater',
    'all_on': 'Turn everything on',
    'all_off': 'Turn everything off',
    'tab_sensors': 'Sensors',
    'sensors_read': 'Read sensors',
    'sensors_reading': 'Reading…',
    'sensor_label': 'Sensor',
    'sensor_has_fluid': 'Liquid present',
    'sensor_error': 'Read error',
    'diag_energy': 'Energy meter',
    'energy_voltage': 'Voltage',
    'energy_current': 'Current',
    'energy_power': 'Power',
    'refresh': 'Refresh',
    'unit_v': 'V',
    'unit_a': 'A',
    'unit_w': 'W',
    'energy_total': 'Total meter',
    'energy_monthly': 'This month',
    'energy_previous_month': 'Previous month',
    'unit_kwh': 'kWh',
  },
  'et': {
    'menu_title': 'Teenindusmenüü',
    'tab_settings': 'Seaded',
    'tab_flavors': 'Lõhnad',
    'tab_diagnostics': 'Diagnostika',
    'tab_journal': 'Logi',
    'exit': 'Välju',
    'price_label': 'Töötluse hind',
    'duration_label': 'Töötluse kestus (sek)',
    'pin_label': 'Teenindusmenüü PIN (4 numbrit)',
    'save': 'Salvesta',
    'saved': 'Salvestatud',
    'err_price': 'Hind: minimaalselt 0.50 €',
    'err_duration': 'Kestus: 10–120 sek',
    'err_pin': 'PIN peab olema 4 numbrit',
    'compressor_purge_label': 'Kompressori puhastus enne pumpade/küttekeha sisselülitamist (sek)',
    'pump_after_heater_label': 'Pumba töö pärast küttekeha väljalülitamist (sek)',
    'err_compressor_purge': 'Kompressori puhastus: 1–30 sek',
    'err_pump_after_heater': 'Pump pärast küttekeha: 1–30 sek',
    'available': 'Olemas',
    'empty_level': 'Tühi',
    'coin_label': 'Münt',
    'coin_yes': 'JAH',
    'coin_no': 'EI',
    'flavor_fallback': 'Lõhn',
    'diag_levels': 'Kanistrite tasemed',
    'diag_manual': 'Käsijuhtimine',
    'diag_manual_warning': 'Ettevaatust: seadmete otsejuhtimine, mööda tavapärasest töölogikast',
    'pump': 'Pump',
    'compressor': 'Kompressor',
    'heater': 'Aurusti küttekeha',
    'all_on': 'Lülita kõik sisse',
    'all_off': 'Lülita kõik välja',
    'tab_sensors': 'Andurid',
    'sensors_read': 'Loe andureid',
    'sensors_reading': 'Loen…',
    'sensor_label': 'Andur',
    'sensor_has_fluid': 'Vedelik olemas',
    'sensor_error': 'Lugemisviga',
    'diag_energy': 'Energiamõõtja',
    'energy_voltage': 'Pinge',
    'energy_current': 'Vool',
    'energy_power': 'Võimsus',
    'refresh': 'Värskenda',
    'unit_v': 'V',
    'unit_a': 'A',
    'unit_w': 'W',
    'energy_total': 'Koguarvesti',
    'energy_monthly': 'Sel kuul',
    'energy_previous_month': 'Eelmisel kuul',
    'unit_kwh': 'kWh',
  },
};

class ServiceMenuScreen extends StatefulWidget {
  const ServiceMenuScreen({super.key});

  @override
  State<ServiceMenuScreen> createState() => _ServiceMenuScreenState();
}

class _ServiceMenuScreenState extends State<ServiceMenuScreen> {
  int _tab = 0; // 0=Настройки, 1=Ароматы, 2=Диагностика, 3=Датчики, 4=Журнал

  Widget _buildTab() {
    switch (_tab) {
      case 0:
        return _SettingsTab();
      case 1:
        return _FlavorsTab();
      case 2:
        return const _DiagnosticsTab();
      case 3:
        return const _SensorsTab();
      default:
        return _JournalTab();
    }
  }

  @override
  Widget build(BuildContext context) {
    final notifier = context.watch<AppNotifier>();
    final lang = notifier.lang;
    final t = _i18n[lang]!;

    final tabs = [
      t['tab_settings']!,
      t['tab_flavors']!,
      t['tab_diagnostics']!,
      t['tab_sensors']!,
      t['tab_journal']!,
    ];

    return Scaffold(
      backgroundColor: const Color(0xFF0A0E1A),
      body: SafeArea(
        child: Column(
          children: [
            // Шапка
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                children: [
                  Text(
                    t['menu_title']!,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const Spacer(),
                  LangSwitcher(current: lang, onChanged: notifier.setLanguage),
                  const SizedBox(width: 16),
                  TextButton(
                    onPressed: () => notifier.transition(AppState.standby),
                    child: Text(
                      t['exit']!,
                      style: const TextStyle(color: Color(0xFF00C6B2)),
                    ),
                  ),
                ],
              ),
            ),

            // Вкладки
            Row(
              children: List.generate(tabs.length, (i) {
                final active = _tab == i;
                return Expanded(
                  child: GestureDetector(
                    onTap: () => setState(() => _tab = i),
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      decoration: BoxDecoration(
                        border: Border(
                          bottom: BorderSide(
                            color: active
                                ? const Color(0xFF00C6B2)
                                : const Color(0xFF1A2233),
                            width: 2,
                          ),
                        ),
                      ),
                      child: Text(
                        tabs[i],
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: active
                              ? const Color(0xFF00C6B2)
                              : const Color(0xFF556677),
                          fontWeight: active
                              ? FontWeight.bold
                              : FontWeight.normal,
                        ),
                      ),
                    ),
                  ),
                );
              }),
            ),

            // Содержимое вкладки
            Expanded(child: _buildTab()),
          ],
        ),
      ),
    );
  }
}

// ============================================================
// ВКЛАДКА: НАСТРОЙКИ
// ============================================================

class _SettingsTab extends StatefulWidget {
  @override
  State<_SettingsTab> createState() => _SettingsTabState();
}

class _SettingsTabState extends State<_SettingsTab> {
  late int _priceCents;
  late TextEditingController _durationCtrl;
  late TextEditingController _pinCtrl;
  late TextEditingController _compressorPurgeCtrl;
  late TextEditingController _pumpAfterHeaterCtrl;

  @override
  void initState() {
    super.initState();
    final config = context.read<AppNotifier>().config;
    _priceCents = config.treatmentPriceCents;
    _durationCtrl =
        TextEditingController(text: config.treatmentDurationS.toString());
    _pinCtrl = TextEditingController(text: config.servicePin);
    _compressorPurgeCtrl =
        TextEditingController(text: config.compressorPurgeS.toString());
    _pumpAfterHeaterCtrl =
        TextEditingController(text: config.pumpAfterHeaterS.toString());
  }

  @override
  void dispose() {
    _durationCtrl.dispose();
    _pinCtrl.dispose();
    _compressorPurgeCtrl.dispose();
    _pumpAfterHeaterCtrl.dispose();
    super.dispose();
  }

  void _changePrice(int deltaCents) {
    setState(() {
      _priceCents = (_priceCents + deltaCents).clamp(50, 999999);
    });
  }

  void _save() {
    final notifier = context.read<AppNotifier>();
    final t = _i18n[notifier.lang]!;
    final duration = int.tryParse(_durationCtrl.text);
    final pin = _pinCtrl.text.trim();
    final compressorPurge = int.tryParse(_compressorPurgeCtrl.text);
    final pumpAfterHeater = int.tryParse(_pumpAfterHeaterCtrl.text);

    if (_priceCents < 50) {
      _snack(t['err_price']!);
      return;
    }
    if (duration == null || duration < 10 || duration > 120) {
      _snack(t['err_duration']!);
      return;
    }
    if (pin.length != 4 || int.tryParse(pin) == null) {
      _snack(t['err_pin']!);
      return;
    }
    if (compressorPurge == null || compressorPurge < 1 || compressorPurge > 30) {
      _snack(t['err_compressor_purge']!);
      return;
    }
    if (pumpAfterHeater == null || pumpAfterHeater < 1 || pumpAfterHeater > 30) {
      _snack(t['err_pump_after_heater']!);
      return;
    }

    final updated = notifier.config.copyWith(
      treatmentPriceCents: _priceCents,
      treatmentDurationS: duration,
      servicePin: pin,
      compressorPurgeS: compressorPurge,
      pumpAfterHeaterS: pumpAfterHeater,
    );
    notifier.saveConfig(updated);
    _snack(t['saved']!);
  }

  void _snack(String msg) {
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final t = _i18n[context.watch<AppNotifier>().lang]!;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _PriceStepper(
            label: t['price_label']!,
            priceCents: _priceCents,
            onChanged: _changePrice,
          ),
          const SizedBox(height: 16),
          _Field(
            label: t['duration_label']!,
            controller: _durationCtrl,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          ),
          const SizedBox(height: 16),
          _Field(
            label: t['pin_label']!,
            controller: _pinCtrl,
            keyboardType: TextInputType.number,
            inputFormatters: [
              FilteringTextInputFormatter.digitsOnly,
              LengthLimitingTextInputFormatter(4),
            ],
            obscure: true,
          ),
          const SizedBox(height: 16),
          _Field(
            label: t['compressor_purge_label']!,
            controller: _compressorPurgeCtrl,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          ),
          const SizedBox(height: 16),
          _Field(
            label: t['pump_after_heater_label']!,
            controller: _pumpAfterHeaterCtrl,
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          ),
          const SizedBox(height: 32),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: _save,
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF00C6B2),
                foregroundColor: Colors.black,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10)),
              ),
              child: Text(
                t['save']!,
                style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ============================================================
// ВКЛАДКА: АРОМАТЫ
// ============================================================

class _FlavorsTab extends StatefulWidget {
  @override
  State<_FlavorsTab> createState() => _FlavorsTabState();
}

class _FlavorsTabState extends State<_FlavorsTab> {
  late List<List<TextEditingController>> _ctrls;
  final _langs = ['ru', 'en', 'et'];

  @override
  void initState() {
    super.initState();
    final names = context.read<AppNotifier>().config.flavorNames;
    _ctrls = List.generate(8, (i) {
      return _langs.map((l) {
        return TextEditingController(text: names[l]?[i] ?? '');
      }).toList();
    });
  }

  @override
  void dispose() {
    for (final row in _ctrls) {
      for (final c in row) {
        c.dispose();
      }
    }
    super.dispose();
  }

  void _save() {
    final notifier = context.read<AppNotifier>();
    final newNames = <String, List<String>>{};
    for (int li = 0; li < _langs.length; li++) {
      newNames[_langs[li]] =
          List.generate(8, (i) => _ctrls[i][li].text.trim());
    }
    final updated = notifier.config.copyWith(flavorNames: newNames);
    notifier.saveConfig(updated);
    final t = _i18n[notifier.lang]!;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(t['saved']!)));
  }

  @override
  Widget build(BuildContext context) {
    final t = _i18n[context.watch<AppNotifier>().lang]!;
    return Column(
      children: [
        // Заголовки колонок
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Row(
            children: [
              const SizedBox(width: 32),
              ...['RU', 'EN', 'ET'].map(
                (l) => Expanded(
                  child: Text(l,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                          color: Color(0xFF556677),
                          fontWeight: FontWeight.bold)),
                ),
              ),
            ],
          ),
        ),
        // Список ароматов
        Expanded(
          child: ListView.separated(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            itemCount: 8,
            separatorBuilder: (_, __) => const SizedBox(height: 8),
            itemBuilder: (_, i) => Row(
              children: [
                SizedBox(
                  width: 32,
                  child: Text('${i + 1}',
                      style: const TextStyle(color: Color(0xFF556677))),
                ),
                ...List.generate(3, (li) {
                  return Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: TextField(
                        controller: _ctrls[i][li],
                        style: const TextStyle(
                            color: Colors.white, fontSize: 13),
                        decoration: InputDecoration(
                          isDense: true,
                          contentPadding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 8),
                          filled: true,
                          fillColor: const Color(0xFF1A2233),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(6),
                            borderSide: BorderSide.none,
                          ),
                        ),
                      ),
                    ),
                  );
                }),
              ],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(16),
          child: SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: _save,
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF00C6B2),
                foregroundColor: Colors.black,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10)),
              ),
              child: Text(t['save']!,
                  style: const TextStyle(
                      fontWeight: FontWeight.bold, fontSize: 16)),
            ),
          ),
        ),
      ],
    );
  }
}

// ============================================================
// ВКЛАДКА: ДИАГНОСТИКА
// ============================================================

class _DiagnosticsTab extends StatefulWidget {
  const _DiagnosticsTab();

  @override
  State<_DiagnosticsTab> createState() => _DiagnosticsTabState();
}

class _DiagnosticsTabState extends State<_DiagnosticsTab> {
  final List<bool> _pumpOn = List.filled(8, false);
  bool _compressorOn = false;
  bool _heaterOn = false;
  bool _busy = false;

  Map<String, double> _energy = {
    'voltage': 0.0,
    'current': 0.0,
    'power': 0.0,
    'totalEnergy': 0.0,
  };
  double _monthlyEnergy = 0.0;
  double _previousMonthEnergy = 0.0;
  Timer? _energyTimer;

  bool _coinDetected = false;
  Timer? _coinTimer;

  @override
  void initState() {
    super.initState();
    _readEnergy();
    _energyTimer = Timer.periodic(const Duration(seconds: 3), (_) => _readEnergy());
    _coinTimer = Timer.periodic(const Duration(milliseconds: 500), (_) => _readCoin());
  }

  @override
  void dispose() {
    _energyTimer?.cancel();
    _coinTimer?.cancel();
    super.dispose();
  }

  Future<void> _readCoin() async {
    final detected = await ModbusService.readCoin();
    if (mounted) setState(() => _coinDetected = detected);
  }

  Future<void> _readEnergy() async {
    final energy = await ModbusService.readEnergy();
    final monthly = await ModbusService.getMonthlyEnergy();
    final previousMonth = await ModbusService.getPreviousMonthEnergy();
    if (mounted) {
      setState(() {
        _energy = energy;
        _monthlyEnergy = monthly;
        _previousMonthEnergy = previousMonth;
      });
    }
  }

  Future<void> _setPump(int i, bool value) async {
    setState(() => _pumpOn[i] = value);
    final ok = await ModbusService.setPump(i, value);
    if (!ok && mounted) setState(() => _pumpOn[i] = !value);
  }

  Future<void> _setCompressor(bool value) async {
    setState(() => _compressorOn = value);
    final ok = await ModbusService.setCompressor(value);
    if (!ok && mounted) setState(() => _compressorOn = !value);
  }

  Future<void> _setHeater(bool value) async {
    setState(() => _heaterOn = value);
    final ok = await ModbusService.setHeater(value);
    if (!ok && mounted) setState(() => _heaterOn = !value);
  }

  Future<void> _allOn() async {
    setState(() => _busy = true);
    for (var i = 0; i < 8; i++) {
      await ModbusService.setPump(i, true);
    }
    await ModbusService.setCompressor(true);
    await ModbusService.setHeater(true);
    if (!mounted) return;
    setState(() {
      _pumpOn.fillRange(0, 8, true);
      _compressorOn = true;
      _heaterOn = true;
      _busy = false;
    });
  }

  Future<void> _allOff() async {
    setState(() => _busy = true);
    await ModbusService.safeAllOff();
    if (!mounted) return;
    setState(() {
      _pumpOn.fillRange(0, 8, false);
      _compressorOn = false;
      _heaterOn = false;
      _busy = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final lang = context.watch<AppNotifier>().lang;
    final t = _i18n[lang]!;
    final levels = context.watch<AppNotifier>().levels;
    final flavors = context.watch<AppNotifier>().config.flavorNames[lang] ?? [];

    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text(t['diag_levels']!,
            style: const TextStyle(
                color: Color(0xFF556677),
                fontWeight: FontWeight.bold,
                fontSize: 13)),
        const SizedBox(height: 12),
        ...List.generate(4, (row) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Row(
              children: [
                Expanded(
                    child: _LevelBadge(
                        index: row * 2, levels: levels, flavors: flavors, t: t)),
                const SizedBox(width: 10),
                Expanded(
                    child: _LevelBadge(
                        index: row * 2 + 1, levels: levels, flavors: flavors, t: t)),
              ],
            ),
          );
        }),
        const SizedBox(height: 4),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: const Color(0xFF141B29),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              Text('${t['coin_label']}:',
                  style: const TextStyle(color: Colors.white, fontSize: 14)),
              const SizedBox(width: 8),
              Text(
                _coinDetected ? t['coin_yes']! : t['coin_no']!,
                style: TextStyle(
                  color: _coinDetected
                      ? const Color(0xFF00C6B2)
                      : const Color(0xFF556677),
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                ),
              ),
            ],
          ),
        ),

        const SizedBox(height: 24),
        const Divider(color: Color(0xFF1A2233)),
        const SizedBox(height: 12),

        Text(t['diag_manual']!,
            style: const TextStyle(
                color: Color(0xFF556677),
                fontWeight: FontWeight.bold,
                fontSize: 13)),
        const SizedBox(height: 4),
        Text(t['diag_manual_warning']!,
            style: const TextStyle(color: Color(0xFF8899AA), fontSize: 12)),
        const SizedBox(height: 12),

        ...(() {
          final toggles = <Widget>[
            ...List.generate(8, (i) {
              final name = flavors.length > i
                  ? flavors[i]
                  : '${t['flavor_fallback']} ${i + 1}';
              return _ToggleRow(
                label: '${t['pump']} ${i + 1} ($name)',
                value: _pumpOn[i],
                onChanged: _busy ? null : (v) => _setPump(i, v),
              );
            }),
            _ToggleRow(
              label: t['compressor']!,
              value: _compressorOn,
              onChanged: _busy ? null : _setCompressor,
            ),
            _ToggleRow(
              label: t['heater']!,
              value: _heaterOn,
              onChanged: _busy ? null : _setHeater,
            ),
          ];
          return List.generate(5, (row) {
            return Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(
                children: [
                  Expanded(child: toggles[row * 2]),
                  const SizedBox(width: 8),
                  Expanded(child: toggles[row * 2 + 1]),
                ],
              ),
            );
          });
        })(),

        const SizedBox(height: 20),
        Row(
          children: [
            Expanded(
              child: ElevatedButton(
                onPressed: _busy ? null : _allOn,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF00C6B2),
                  foregroundColor: Colors.black,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                ),
                child: Text(t['all_on']!,
                    style: const TextStyle(fontWeight: FontWeight.bold)),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: ElevatedButton(
                onPressed: _busy ? null : _allOff,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFE53935),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                ),
                child: Text(t['all_off']!,
                    style: const TextStyle(fontWeight: FontWeight.bold)),
              ),
            ),
          ],
        ),

        const SizedBox(height: 24),
        const Divider(color: Color(0xFF1A2233)),
        const SizedBox(height: 12),

        Row(
          children: [
            Text(t['diag_energy']!,
                style: const TextStyle(
                    color: Color(0xFF556677),
                    fontWeight: FontWeight.bold,
                    fontSize: 13)),
            const Spacer(),
            TextButton(
              onPressed: _readEnergy,
              child: Text(t['refresh']!,
                  style: const TextStyle(color: Color(0xFF00C6B2))),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: const Color(0xFF141B29),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              Expanded(
                child: _EnergyMetric(
                  label: t['energy_voltage']!,
                  value: _energy['voltage'] ?? 0.0,
                  unit: t['unit_v']!,
                ),
              ),
              Expanded(
                child: _EnergyMetric(
                  label: t['energy_current']!,
                  value: _energy['current'] ?? 0.0,
                  unit: t['unit_a']!,
                ),
              ),
              Expanded(
                child: _EnergyMetric(
                  label: t['energy_power']!,
                  value: _energy['power'] ?? 0.0,
                  unit: t['unit_w']!,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: const Color(0xFF141B29),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${t['energy_total']}: '
                '${(_energy['totalEnergy'] ?? 0.0).toStringAsFixed(2)} ${t['unit_kwh']}',
                style: const TextStyle(color: Colors.white, fontSize: 14),
              ),
              const SizedBox(height: 6),
              Text(
                '${t['energy_monthly']}: '
                '${_monthlyEnergy.toStringAsFixed(2)} ${t['unit_kwh']}',
                style: const TextStyle(color: Colors.white, fontSize: 14),
              ),
              const SizedBox(height: 6),
              Text(
                '${t['energy_previous_month']}: '
                '${_previousMonthEnergy.toStringAsFixed(2)} ${t['unit_kwh']}',
                style: const TextStyle(color: Colors.white, fontSize: 14),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _EnergyMetric extends StatelessWidget {
  final String label;
  final double value;
  final String unit;

  const _EnergyMetric({
    required this.label,
    required this.value,
    required this.unit,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: const TextStyle(color: Color(0xFF8899AA), fontSize: 12)),
        const SizedBox(height: 4),
        Text('${value.toStringAsFixed(1)} $unit',
            style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.bold,
                fontSize: 16)),
      ],
    );
  }
}

// ============================================================
// ВКЛАДКА: ДАТЧИКИ
// ============================================================

class _SensorsTab extends StatefulWidget {
  const _SensorsTab();

  @override
  State<_SensorsTab> createState() => _SensorsTabState();
}

class _SensorsTabState extends State<_SensorsTab> {
  List<bool>? _levels;
  bool _loading = false;
  String? _error;

  Future<void> _readSensors() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final levels = await ModbusService.readLevels();
      if (!mounted) return;
      setState(() {
        _levels = levels;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = _i18n[context.watch<AppNotifier>().lang]!;

    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            onPressed: _loading ? null : _readSensors,
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF00C6B2),
              foregroundColor: Colors.black,
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
            ),
            child: Text(
              _loading ? t['sensors_reading']! : t['sensors_read']!,
              style:
                  const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
          ),
        ),
        if (_error != null) ...[
          const SizedBox(height: 16),
          Text(
            '${t['sensor_error']}: $_error',
            style: const TextStyle(color: Color(0xFFE53935), fontSize: 13),
          ),
        ],
        const SizedBox(height: 20),
        ...List.generate(8, (i) {
          final value =
              _levels != null && _levels!.length > i ? _levels![i] : null;
          return Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: _SensorRow(index: i, value: value, t: t),
          );
        }),
      ],
    );
  }
}

class _SensorRow extends StatelessWidget {
  final int index;
  // null = ещё не прочитано; true = жидкость есть; false = пусто
  // (совпадает с соглашением ModbusService.readLevels() и _LevelBadge)
  final bool? value;
  final Map<String, String> t;

  const _SensorRow({
    required this.index,
    required this.value,
    required this.t,
  });

  @override
  Widget build(BuildContext context) {
    Color dotColor;
    String label;
    if (value == null) {
      dotColor = const Color(0xFF556677);
      label = '—';
    } else if (value == true) {
      dotColor = const Color(0xFF00C6B2);
      label = t['sensor_has_fluid']!;
    } else {
      dotColor = const Color(0xFFE53935);
      label = t['empty_level']!;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF141B29),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Container(
            width: 14,
            height: 14,
            decoration:
                BoxDecoration(color: dotColor, shape: BoxShape.circle),
          ),
          const SizedBox(width: 12),
          Text(
            '${t['sensor_label']} $index',
            style: const TextStyle(color: Colors.white, fontSize: 14),
          ),
          const Spacer(),
          Text(
            label,
            style: TextStyle(
                color: dotColor, fontWeight: FontWeight.bold, fontSize: 13),
          ),
        ],
      ),
    );
  }
}

class _ToggleRow extends StatelessWidget {
  final String label;
  final bool value;
  final ValueChanged<bool>? onChanged;

  const _ToggleRow({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white, fontSize: 13)),
          ),
          Switch(
            value: value,
            onChanged: onChanged,
            activeThumbColor: const Color(0xFF00C6B2),
          ),
        ],
      ),
    );
  }
}

class _LevelBadge extends StatelessWidget {
  final int index;
  final List<bool> levels;
  final List<String> flavors;
  final Map<String, String> t;

  const _LevelBadge({
    required this.index,
    required this.levels,
    required this.flavors,
    required this.t,
  });

  @override
  Widget build(BuildContext context) {
    final hasFluid = levels.length > index ? levels[index] : false;
    final name = flavors.length > index
        ? flavors[index]
        : '${t['flavor_fallback']} ${index + 1}';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF141B29),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('${index + 1}. $name',
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white, fontSize: 13)),
          const SizedBox(height: 4),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: hasFluid
                  ? const Color(0xFF00C6B2).withValues(alpha: 0.15)
                  : const Color(0xFFE53935).withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              hasFluid ? t['available']! : t['empty_level']!,
              style: TextStyle(
                color: hasFluid
                    ? const Color(0xFF00C6B2)
                    : const Color(0xFFE53935),
                fontWeight: FontWeight.bold,
                fontSize: 11,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ============================================================
// ВСПОМОГАТЕЛЬНЫЙ ВИДЖЕТ: степпер цены (±50 центов)
// ============================================================

class _PriceStepper extends StatelessWidget {
  final String label;
  final int priceCents;
  final ValueChanged<int> onChanged;

  const _PriceStepper({
    required this.label,
    required this.priceCents,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: const TextStyle(color: Color(0xFF8899AA), fontSize: 13)),
        const SizedBox(height: 6),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: const Color(0xFF1A2233),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            children: [
              _StepButton(
                icon: Icons.remove,
                onPressed: () => onChanged(-50),
              ),
              Expanded(
                child: Text(
                  '${(priceCents / 100).toStringAsFixed(2)} €',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.bold),
                ),
              ),
              _StepButton(
                icon: Icons.add,
                onPressed: () => onChanged(50),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _StepButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onPressed;

  const _StepButton({required this.icon, required this.onPressed});

  @override
  Widget build(BuildContext context) {
    return IconButton(
      onPressed: onPressed,
      icon: Icon(icon, color: const Color(0xFF00C6B2)),
      style: IconButton.styleFrom(
        backgroundColor: const Color(0xFF0A0E1A),
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8)),
      ),
    );
  }
}

// ============================================================
// ВСПОМОГАТЕЛЬНЫЙ ВИДЖЕТ: поле ввода
// ============================================================

class _Field extends StatelessWidget {
  final String label;
  final TextEditingController controller;
  final TextInputType keyboardType;
  final List<TextInputFormatter> inputFormatters;
  final bool obscure;

  const _Field({
    required this.label,
    required this.controller,
    required this.keyboardType,
    required this.inputFormatters,
    this.obscure = false,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: const TextStyle(
                color: Color(0xFF8899AA), fontSize: 13)),
        const SizedBox(height: 6),
        TextField(
          controller: controller,
          keyboardType: keyboardType,
          inputFormatters: inputFormatters,
          obscureText: obscure,
          style: const TextStyle(color: Colors.white),
          decoration: InputDecoration(
            filled: true,
            fillColor: const Color(0xFF1A2233),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide.none,
            ),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          ),
        ),
      ],
    );
  }
}

// ============================================================
// ВКЛАДКА: ЖУРНАЛ СОБЫТИЙ
// ============================================================

class _JournalTab extends StatefulWidget {
  @override
  State<_JournalTab> createState() => _JournalTabState();
}

class _JournalTabState extends State<_JournalTab> {
  List<CloudEvent> _events = [];
  int _pending = 0;
  bool _loading = true;

  static const _eventLabels = {
    'app_started': 'Запуск приложения',
    'service_login_ok': 'Вход в сервисное меню',
    'unauthorized_access': 'Несанкционированный доступ',
    'master_code_used': 'Использован мастер-код',
    'factory_reset': 'Сброс к заводским',
    'low_liquid': 'Заканчивается жидкость',
    'session_complete': 'Сессия завершена',
    'hardware_error': 'Ошибка оборудования',
    'energy_reading': 'Показания энергии',
  };

  static const _alarmTypes = {
    'unauthorized_access',
    'master_code_used',
    'factory_reset',
    'hardware_error',
  };

  static const _warnTypes = {
    'low_liquid',
  };

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final list = await CloudService.history();
    final pending = await CloudService.pendingCount();
    if (!mounted) return;
    setState(() {
      _events = list.reversed.toList(); // новые сверху
      _pending = pending;
      _loading = false;
    });
  }

  Future<void> _confirmClear() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: const Color(0xFF1A2233),
        title: const Text(
          'Очистить журнал?',
          style: TextStyle(color: Colors.white, fontSize: 18),
        ),
        content: const Text(
          'История событий на аппарате будет удалена. '
          'События, уже отправленные в облако, там останутся.',
          style: TextStyle(color: Color(0xFF8899AA), fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text(
              'Отмена',
              style: TextStyle(color: Color(0xFF556677)),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text(
              'Очистить',
              style: TextStyle(
                color: Color(0xFFE53935),
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await CloudService.clearHistory();
      await _load();
    }
  }

  Future<void> _flushNow() async {
    await CloudService.flush();
    await _load();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Отправка выполнена')),
    );
  }

  Color _colorFor(String type) {
    if (_alarmTypes.contains(type)) return const Color(0xFFE53935);
    if (_warnTypes.contains(type)) return const Color(0xFFFFAA00);
    return const Color(0xFF00C6B2);
  }

  IconData _iconFor(String type) {
    if (_alarmTypes.contains(type)) return Icons.warning_amber_rounded;
    if (_warnTypes.contains(type)) return Icons.opacity;
    return Icons.check_circle_outline;
  }

  String _formatTs(DateTime ts) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(ts.day)}.${two(ts.month)} '
        '${two(ts.hour)}:${two(ts.minute)}:${two(ts.second)}';
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(
        child: CircularProgressIndicator(color: Color(0xFF00C6B2)),
      );
    }

    return Column(
      children: [
        // Шапка: аппарат + очередь отправки
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Row(
            children: [
              Text(
                CloudService.deviceId,
                style: const TextStyle(
                  color: Color(0xFF00C6B2),
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(width: 12),
              Text(
                'Событий: ${_events.length}',
                style: const TextStyle(
                  color: Color(0xFF556677),
                  fontSize: 12,
                ),
              ),
              const Spacer(),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: _pending > 0
                      ? const Color(0xFFFFAA00).withValues(alpha: 0.15)
                      : const Color(0xFF00C6B2).withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  _pending > 0 ? 'Не отправлено: $_pending' : 'Всё отправлено',
                  style: TextStyle(
                    color: _pending > 0
                        ? const Color(0xFFFFAA00)
                        : const Color(0xFF00C6B2),
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
        ),

        // Список событий
        Expanded(
          child: _events.isEmpty
              ? const Center(
                  child: Text(
                    'Журнал пуст',
                    style: TextStyle(color: Color(0xFF556677), fontSize: 15),
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  itemCount: _events.length,
                  separatorBuilder: (_, _) =>
                      const Divider(color: Color(0xFF1A2233), height: 1),
                  itemBuilder: (_, i) {
                    final e = _events[i];
                    final color = _colorFor(e.type);
                    final label = _eventLabels[e.type] ?? e.type;

                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(_iconFor(e.type), color: color, size: 20),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  label,
                                  style: TextStyle(
                                    color: color,
                                    fontSize: 14,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  _formatTs(e.ts),
                                  style: const TextStyle(
                                    color: Color(0xFF556677),
                                    fontSize: 12,
                                  ),
                                ),
                                if (e.data.isNotEmpty) ...[
                                  const SizedBox(height: 4),
                                  Text(
                                    jsonEncode(e.data),
                                    style: const TextStyle(
                                      color: Color(0xFF8899AA),
                                      fontSize: 11,
                                      height: 1.3,
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
        ),

        // Кнопки
        Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: _load,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFF00C6B2),
                    side: const BorderSide(color: Color(0xFF00C6B2)),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  child: const Text('Обновить'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton(
                  onPressed: _flushNow,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFF00C6B2),
                    side: const BorderSide(color: Color(0xFF00C6B2)),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  child: const Text('Отправить'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton(
                  onPressed: _confirmClear,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFFE53935),
                    side: const BorderSide(color: Color(0xFFE53935)),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  child: const Text('Очистить'),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
