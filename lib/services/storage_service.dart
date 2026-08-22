import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class StorageService {
  static const _channel = MethodChannel('com.carfog.dryfog/storage');

  // Корневые пути всех примонтированных томов хранилища (SD-карта
  // первой, встроенная память последней) через официальный Android API.
  // Прямой листинг /storage/ из приложения запрещён политикой хранения,
  // а SD-карта монтируется под ID тома (например /storage/DCA3-BA1A),
  // не под предсказуемым именем — поэтому просто перебрать кандидатов
  // не получится.
  static Future<List<String>> listVolumeRoots() async {
    try {
      final result = await _channel.invokeMethod<List>('listVolumeRoots');
      return result?.map((e) => e as String).toList() ?? const [];
    } catch (e) {
      debugPrint('StorageService.listVolumeRoots error: $e');
      return const [];
    }
  }
}
