import 'package:flutter/foundation.dart';
import '../models/remote_limits.dart';

// Краткая запись цикла обработки (1.10.1): температура, прогрев, ТЭН, фазы.
// ТОЛЬКО запись: ни одно решение цикла отсюда не читается. Источники — уже
// существующие чтения термопары (preparing.dart / treating.dart) и уже
// существующие команды на ТЭН; дополнительных опросов шины нет.
//
// Жизненный цикл: begin() — SessionService.start (сессия создана);
// отметки фаз/температуры/ТЭНа — экраны; finish() — SessionService._finish
// (одна сводка на сессию, и при успехе, и при прерывании). Любая ошибка
// внутри сборщика проглатывается: на цикл и на отправку session_complete она
// не влияет (поля просто отсутствуют).
//
// Фазы (имена — как в данных события, phase_<имя>_s):
//   preheat            — экран прогрева (preparing.dart) от входа до
//                        достижения цели или отказа/отмены;
//   compressor_startup — treating.dart, этап компрессора (_Phase.compressor);
//   treating           — этап обработки (насос), _Phase.treating;
//   purge              — продувка после обработки, _Phase.shutdown.
class CycleSummary {
  CycleSummary._();

  // Подменяется в тестах.
  @visibleForTesting
  static DateTime Function() now = DateTime.now;

  static _Cycle? _c;

  static bool get active => _c != null;

  static void begin() => _guard(() => _c = _Cycle(now()));

  // Новая фаза: закрывает предыдущую.
  static void enterPhase(String name) => _guard(() {
    final c = _c;
    if (c == null) return;
    final t = now();
    c.closePhase(t);
    c.phase = name;
    c.phaseSince = t;
  });

  // Годное показание термопары, которое экран уже прочитал.
  static void recordTemp(double? tempC) => _guard(() {
    final c = _c;
    if (c == null || tempC == null || !tempC.isFinite) return;
    final t = now();
    c.startTempC ??= tempC;
    if (c.peakTempC == null || tempC > c.peakTempC!) c.peakTempC = tempC;
    c.finalTempC = tempC;
    c.addCurvePoint(t, tempC);
  });

  // Команда на реле ТЭНа прошла (on) или катушка выключена (off).
  // Переключением считается только смена состояния.
  static void heaterCommanded(bool on) => _guard(() {
    final c = _c;
    if (c == null) return;
    final t = now();
    if (on) {
      c.heaterFirstOnAt ??= t;
      if (c.heaterOnSince == null) {
        c.heaterOnSince = t;
        c.heaterSwitches++;
      }
    } else if (c.heaterOnSince != null) {
      c.heaterOn += t.difference(c.heaterOnSince!);
      c.heaterOnSince = null;
      c.heaterSwitches++;
    }
  });

  // Цель прогрева достигнута (тот же момент, что markPreheatReached).
  static void preheatReached(double tempC) => _guard(() {
    final c = _c;
    if (c == null || c.preheatS != null) return;
    final at = c.heaterFirstOnAt;
    if (at != null) c.preheatS = now().difference(at).inMilliseconds / 1000.0;
    c.preheatEndTempC = tempC;
  });

  // Прогрев не завершился; reason — код, который экран уже пишет в журнал
  // ошибок (HEAT_TIMEOUT, HEAT_OVERHEAT, HEAT_USER_CANCEL…).
  static void preheatAborted(String reason) => _guard(() {
    final c = _c;
    if (c == null || c.preheatS != null || c.preheatAbortReason != null) return;
    c.preheatAbortReason = reason;
  });

  // Итог и сброс. null — сводки нет (цикл не начинался или сбой сборщика).
  static Map<String, dynamic>? finish() {
    final c = _c;
    _c = null;
    if (c == null) return null;
    try {
      return c.toJson(now());
    } catch (e) {
      debugPrint('CycleSummary.finish error: $e');
      return null;
    }
  }

  @visibleForTesting
  static void reset() => _c = null;

  static void _guard(void Function() f) {
    try {
      f();
    } catch (e) {
      debugPrint('CycleSummary error: $e');
    }
  }
}

double _r1(double v) => (v * 10).round() / 10;

class _Cycle {
  _Cycle(this.startedAt);

  final DateTime startedAt;

  String? phase;
  DateTime? phaseSince;
  final Map<String, double> phaseS = {};

  double? startTempC;
  double? peakTempC;
  double? finalTempC;
  double? preheatEndTempC;
  double? preheatS;
  String? preheatAbortReason;

  DateTime? heaterFirstOnAt;
  DateTime? heaterOnSince;
  Duration heaterOn = Duration.zero;
  int heaterSwitches = 0;

  // Облегчённая кривая: не чаще шага, не больше maxPoints; при переполнении
  // каждая вторая точка выбрасывается, шаг удваивается.
  final List<double> curve = [];
  int curveStepS = CycleSummaryLimits.curveMinStep.inSeconds;
  DateTime? lastCurveAt;

  void closePhase(DateTime t) {
    final p = phase;
    final since = phaseSince;
    if (p == null || since == null) return;
    phaseS[p] = (phaseS[p] ?? 0) + t.difference(since).inMilliseconds / 1000.0;
    phase = null;
    phaseSince = null;
  }

  void addCurvePoint(DateTime t, double tempC) {
    final last = lastCurveAt;
    if (last != null && t.difference(last).inSeconds < curveStepS) return;
    curve.add(_r1(tempC));
    lastCurveAt = t;
    if (curve.length > CycleSummaryLimits.curveMaxPoints) {
      final kept = <double>[
        for (var i = 0; i < curve.length; i += 2) curve[i],
      ];
      curve
        ..clear()
        ..addAll(kept);
      curveStepS *= 2;
    }
  }

  Map<String, dynamic> toJson(DateTime t) {
    closePhase(t);
    var onTotal = heaterOn;
    if (heaterOnSince != null) onTotal += t.difference(heaterOnSince!);
    return {
      if (preheatS != null) 'preheat_s': _r1(preheatS!),
      if (startTempC != null) 'start_temp_c': _r1(startTempC!),
      if (preheatEndTempC != null) 'preheat_end_temp_c': _r1(preheatEndTempC!),
      if (peakTempC != null) 'peak_temp_c': _r1(peakTempC!),
      if (finalTempC != null) 'final_temp_c': _r1(finalTempC!),
      if (heaterFirstOnAt != null) ...{
        'heater_switches': heaterSwitches,
        'heater_on_s': _r1(onTotal.inMilliseconds / 1000.0),
      },
      for (final e in phaseS.entries) 'phase_${e.key}_s': _r1(e.value),
      if (preheatAbortReason != null) ...{
        'preheat_aborted': true,
        'preheat_abort_reason': preheatAbortReason,
      },
      if (curve.length >= 2) ...{
        'temp_curve_c': List<double>.of(curve),
        'temp_curve_step_s': curveStepS,
      },
    };
  }
}
