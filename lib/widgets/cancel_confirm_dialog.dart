import 'package:flutter/material.dart';

// Окно подтверждения «Отмена» на экранах прогрева и обработки. Пока окно
// открыто, экран может смениться сам (прогрев дошёл до цели, сбой, конец
// цикла) — dismiss() из dispose закрывает окно, чтобы оно не осталось над
// следующим экраном и не остановило уже другую фазу.
class CancelConfirmDialog {
  BuildContext? _ctx;

  bool get isOpen => _ctx != null;

  Future<bool> ask(
    BuildContext context, {
    required String title,
    required String body,
    required String no,
    required String yes,
  }) async {
    if (_ctx != null) return false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        _ctx = ctx;
        return AlertDialog(
          title: Text(title),
          content: Text(body),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text(no),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text(yes),
            ),
          ],
        );
      },
    );
    _ctx = null;
    return ok == true;
  }

  // Из dispose: дерево заблокировано — закрыть после кадра.
  void dismiss() {
    final c = _ctx;
    if (c == null) return;
    _ctx = null;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (c.mounted) Navigator.of(c).pop(false);
    });
  }
}
