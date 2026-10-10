import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../models/app_state.dart';
import '../../models/bus_map.dart';
import '../../services/app_log_service.dart';
import '../../services/cloud_service.dart';

// Секция «Порт шины RS485» в сервисном меню (вкладка «Диагностика»).
// Порт — настройка AppConfig.busPort: менять только по указанию
// техподдержки. Запрещённые узлы (BusPortPolicy.forbidden) показываются, но
// выбрать их нельзя — только предупреждение. Смена требует ввода сервисного
// PIN, пишется в журнал и в облако (config_changed) и вступает в силу при
// перезапуске приложения (шина открывается один раз при старте).

const Map<String, Map<String, String>> _i18n = {
  'ru': {
    'title': 'Порт шины RS485',
    'warn':
        'Менять только по указанию техподдержки. Неверный порт — шина '
        'не работает.',
    'current': 'Сейчас',
    'restart': 'Новый порт вступит в силу после перезапуска приложения.',
    'forbidden':
        'Этот узел запрещён: он занят системой (Bluetooth или '
        'модем 4G). Выберите другой.',
    'not_found': 'не найден',
    'forbidden_tag': 'запрещён',
    'pin_title': 'Подтвердите PIN',
    'pin_body': 'Сменить порт шины на',
    'pin_label': 'PIN сервисного меню',
    'pin_wrong': 'Неверный PIN',
    'cancel': 'Отмена',
    'apply': 'Сменить',
    'saved': 'Порт сохранён. Перезапустите приложение.',
    'none': 'Подходящих узлов не найдено',
  },
  'en': {
    'title': 'RS485 bus port',
    'warn':
        'Change only when told by technical support. A wrong port '
        'stops the bus.',
    'current': 'Current',
    'restart': 'The new port takes effect after the app restarts.',
    'forbidden':
        'This node is forbidden: it is used by the system '
        '(Bluetooth or the 4G modem). Pick another.',
    'not_found': 'not found',
    'forbidden_tag': 'forbidden',
    'pin_title': 'Confirm PIN',
    'pin_body': 'Change the bus port to',
    'pin_label': 'Service menu PIN',
    'pin_wrong': 'Wrong PIN',
    'cancel': 'Cancel',
    'apply': 'Change',
    'saved': 'Port saved. Restart the app.',
    'none': 'No suitable nodes found',
  },
  'et': {
    'title': 'RS485 siini port',
    'warn':
        'Muuda ainult tehnilise toe juhendamisel. Vale port peatab '
        'siini.',
    'current': 'Praegu',
    'restart': 'Uus port rakendub rakenduse taaskäivitamisel.',
    'forbidden':
        'See sõlm on keelatud: seda kasutab süsteem (Bluetooth '
        'või 4G modem). Vali teine.',
    'not_found': 'ei leitud',
    'forbidden_tag': 'keelatud',
    'pin_title': 'Kinnita PIN',
    'pin_body': 'Muuda siini port',
    'pin_label': 'Teenindusmenüü PIN',
    'pin_wrong': 'Vale PIN',
    'cancel': 'Tühista',
    'apply': 'Muuda',
    'saved': 'Port salvestatud. Taaskäivita rakendus.',
    'none': 'Sobivaid sõlmi ei leitud',
  },
};

// Кандидаты для списка: узлы, которые существуют на планшете, плюс
// запрещённые (показываются с пометкой) и текущий порт.
List<String> candidateNodes({
  String? current,
  bool Function(String path)? exists,
}) {
  bool has(String p) => exists != null
      ? exists(p)
      : FileSystemEntity.typeSync(p) != FileSystemEntityType.notFound;
  final out = <String>[];
  void scan(String prefix, int count) {
    for (var i = 0; i < count; i++) {
      final p = '$prefix$i';
      if (has(p)) out.add(p);
    }
  }

  scan('/dev/ttyS', 16);
  scan('/dev/ttyUSB', 8);
  scan('/dev/ttyACM', 8);
  if (current != null && !out.contains(current)) out.add(current);
  return out;
}

class BusPortSection extends StatefulWidget {
  // Подмена для тестов: список найденных узлов.
  final List<String> Function(String? current)? discover;
  const BusPortSection({super.key, this.discover});

  @override
  State<BusPortSection> createState() => _BusPortSectionState();
}

class _BusPortSectionState extends State<BusPortSection> {
  List<String> _nodes = const [];
  bool _forbiddenWarning = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  void _refresh() {
    final current = context.read<AppNotifier>().config.busPort;
    final found = widget.discover != null
        ? widget.discover!(current)
        : candidateNodes(current: current);
    setState(() => _nodes = found);
  }

  Future<void> _select(String port, Map<String, String> t) async {
    if (BusPortPolicy.check(port) == BusPortCheck.forbidden) {
      setState(() => _forbiddenWarning = true);
      return;
    }
    if (BusPortPolicy.check(port) != BusPortCheck.ok) return;
    setState(() => _forbiddenWarning = false);
    final notifier = context.read<AppNotifier>();
    if (port == notifier.config.busPort) return;
    final pin = await _askPin(port, t);
    if (pin == null || !mounted) return;
    if (pin != notifier.config.servicePin) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(t['pin_wrong']!)));
      return;
    }
    final old = notifier.config.busPort;
    await notifier.saveConfig(notifier.config.copyWith(busPort: port));
    AppLog.log('Bus', 'порт шины изменён вручную: $old → $port');
    unawaited(
      CloudService.report(
        CloudEventType.configChanged,
        data: {'code': 'bus_port_changed', 'from': old, 'to': port},
      ),
    );
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(t['saved']!)));
  }

  Future<String?> _askPin(String port, Map<String, String> t) {
    return showDialog<String>(
      context: context,
      builder: (ctx) => _PinDialog(port: port, t: t),
    );
  }

  @override
  Widget build(BuildContext context) {
    final notifier = context.watch<AppNotifier>();
    final t = _i18n[notifier.serviceLang] ?? _i18n['ru']!;
    final current = notifier.config.busPort;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF141B29),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFF334455)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            t['title']!,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 20,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            t['warn']!,
            style: const TextStyle(color: Color(0xFFFFAA00), fontSize: 16),
          ),
          const SizedBox(height: 12),
          Text(
            '${t['current']}: $current',
            style: const TextStyle(color: Color(0xFF00C6B2), fontSize: 18),
          ),
          const SizedBox(height: 12),
          if (_nodes.isEmpty)
            Text(
              t['none']!,
              style: const TextStyle(color: Colors.white54, fontSize: 16),
            )
          else
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final p in _nodes)
                  _NodeChip(
                    path: p,
                    selected: p == current,
                    forbidden: BusPortPolicy.check(p) == BusPortCheck.forbidden,
                    tag: BusPortPolicy.check(p) == BusPortCheck.forbidden
                        ? t['forbidden_tag']!
                        : null,
                    onTap: () => _select(p, t),
                  ),
              ],
            ),
          if (_forbiddenWarning) ...[
            const SizedBox(height: 12),
            Text(
              t['forbidden']!,
              style: const TextStyle(color: Color(0xFFE53935), fontSize: 16),
            ),
          ],
          const SizedBox(height: 12),
          Text(
            t['restart']!,
            style: const TextStyle(color: Color(0xFF8899AA), fontSize: 14),
          ),
        ],
      ),
    );
  }
}

class _NodeChip extends StatelessWidget {
  final String path;
  final bool selected;
  final bool forbidden;
  final String? tag;
  final VoidCallback onTap;

  const _NodeChip({
    required this.path,
    required this.selected,
    required this.forbidden,
    required this.tag,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = forbidden
        ? const Color(0xFF8B3A3A)
        : selected
        ? const Color(0xFF00C6B2)
        : const Color(0xFF8899AA);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Container(
        constraints: const BoxConstraints(minHeight: 56),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected ? color.withValues(alpha: 0.15) : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: color, width: selected ? 2 : 1),
        ),
        child: Text(
          tag == null ? path : '$path · $tag',
          style: TextStyle(color: color, fontSize: 18),
        ),
      ),
    );
  }
}

// Диалог владеет контроллером сам: dispose вместе с состоянием диалога, а не
// сразу после закрытия маршрута (иначе поле ещё анимируется с освобождённым
// контроллером).
class _PinDialog extends StatefulWidget {
  final String port;
  final Map<String, String> t;
  const _PinDialog({required this.port, required this.t});

  @override
  State<_PinDialog> createState() => _PinDialogState();
}

class _PinDialogState extends State<_PinDialog> {
  final _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = widget.t;
    return AlertDialog(
      backgroundColor: const Color(0xFF141B29),
      title: Text(t['pin_title']!, style: const TextStyle(color: Colors.white)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${t['pin_body']} ${widget.port}?',
            style: const TextStyle(color: Colors.white70, fontSize: 18),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _ctrl,
            autofocus: true,
            obscureText: true,
            keyboardType: TextInputType.number,
            maxLength: 4,
            style: const TextStyle(color: Colors.white, fontSize: 24),
            decoration: InputDecoration(
              labelText: t['pin_label'],
              labelStyle: const TextStyle(color: Color(0xFF8899AA)),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(
            t['cancel']!,
            style: const TextStyle(color: Color(0xFF8899AA), fontSize: 18),
          ),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(_ctrl.text),
          child: Text(
            t['apply']!,
            style: const TextStyle(
              color: Color(0xFFE53935),
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
      ],
    );
  }
}
