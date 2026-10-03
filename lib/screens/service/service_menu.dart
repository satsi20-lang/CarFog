import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../models/app_state.dart';
import '../../models/bus_map.dart';
import '../../widgets/lang_switcher.dart';
import '../../models/out_of_service.dart';
import '../../models/remote_limits.dart';
import '../../services/cloud_service.dart';
import '../../services/master_code_service.dart';
import '../../services/pin_policy.dart';
import '../../services/heater_trial_service.dart';
import '../../services/remote_command_guard.dart';
import '../../services/diagnostics_service.dart';
import '../../services/modbus_service.dart';
import '../../services/out_of_service_service.dart';
import '../../services/sync_service.dart';
import '../../services/system_service.dart';
import '../../services/update_service.dart';

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
    'err_price': 'Цена: от 0.50 € до 20 €',
    'err_duration': 'Длительность: 10–120 сек',
    'err_pin': 'PIN — 4 цифры',
    'err_pin_weak':
        'PIN слишком простой: не 1234, не одинаковые цифры, не по порядку',
    'mc_title': 'Мастер-код (аварийный вход)',
    'mc_ack': 'Мастер-код записан',
    'mc_not_ack': 'Мастер-код НЕ записан — ввод в эксплуатацию не завершён',
    'mc_show': 'Показать мастер-код',
    'mc_change': 'Сменить мастер-код',
    'mc_change_warn':
        'Прежний мастер-код перестанет действовать. Новый будет показан один раз. Продолжить?',
    'mc_shown_title': 'Мастер-код этого аппарата',
    'mc_shown_warn':
        'Запишите код и храните отдельно от аппарата. Повторно показать его нельзя.',
    'mc_written': 'Я записал',
    'mc_close_unconfirmed': 'Закрыть без подтверждения',
    'mc_hint':
        'Код нужен, если забыт сервисный PIN. Он свой у каждого аппарата.',
    'cancel_btn': 'Отмена',
    'compressor_purge_label':
        'Продувка компрессора до включения насосов и ТЭНа (сек)',
    'pump_after_heater_label': 'Работа насоса после выключения ТЭНа (сек)',
    'err_compressor_purge': 'Продувка компрессора: 0–60 сек',
    'err_pump_after_heater': 'Работа насоса после ТЭНа: 0–60 сек',
    'tariff_label': 'Тариф на электроэнергию (€/кВт·ч)',
    'err_tariff': 'Тариф: неотрицательное число',
    'idle_cost_label': 'Стоимость простоя за сутки (справочно)',
    'available': 'Есть',
    'empty_level': 'Пусто',
    'flavor_fallback': 'Аромат',
    'coin_label': 'Монета',
    'coin_yes': 'ДА',
    'coin_no': 'НЕТ',
    'temp_label': 'Температура',
    'temp_unavailable': '--',
    'not_installed': 'не установлено',
    'diag_levels': 'Уровни канистр',
    'diag_manual': 'Ручное управление',
    'diag_manual_warning':
        'Осторожно: прямое управление оборудованием, минуя обычную логику работы аппарата',
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
    'terminal_section': 'Платёжный терминал',
    'terminal_enabled': 'Терминал подключён',
    'terminal_channel': 'Канал DI',
    'terminal_mode': 'Режим распознавания',
    'terminal_mode_edge': 'По фронту (импульс)',
    'terminal_mode_level': 'По уровню (удержание)',
    'terminal_guard': 'Защитная пауза (мс)',
    'terminal_state': 'Вход сейчас',
    'terminal_state_high': 'ВЫСОКИЙ',
    'terminal_state_low': 'НИЗКИЙ',
    'terminal_state_unknown': '—',
    'terminal_observe_start': 'Начать наблюдение',
    'terminal_observe_stop': 'Остановить наблюдение',
    'terminal_journal': 'Журнал сигнала',
    'terminal_journal_clear': 'Очистить журнал',
    'terminal_journal_empty':
        'Пока пусто — начните наблюдение и приложите карту к терминалу',
    'err_terminal_channel': 'Канал: 0–15',
    'err_terminal_guard': 'Защитная пауза: минимум 100 мс',
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
    'last_cycle_voltage': 'Напряжение сети (последний цикл)',
    'unit_kwh': 'кВт⋅ч',
    'tab_cloud': 'Облако',
    'cloud_enabled': 'Отправлять данные в облако',
    'rd_title': 'Удалённая диагностика',
    'up_title': 'Обновление приложения',
    'up_version': 'Версия',
    'up_backup': 'Резервная версия',
    'up_backup_none': 'нет (появится после первого обновления)',
    'up_last': 'Последнее обновление',
    'up_last_none': 'ещё не было',
    'up_rollback': 'Откатить',
    'up_rollback_title': 'Откатить на резервную версию?',
    'up_rollback_body':
        'Приложение будет заменено резервной версией и перезапущено. Данные аппарата не стираются. Во время отката оплата не принимается.',
    'up_rollback_started': 'Откат запущен',
    'up_rollback_failed': 'Откат не запущен',
    'up_adb': 'ADB по сети: сохранять после перезагрузки',
    'up_adb_warn':
        'Любой, кто в одной сети с планшетом, сможет подключиться к нему по ADB. Включайте только на время обслуживания и в доверенной сети. Включить?',
    'up_adb_state': 'Состояние ADB по сети',
    'up_adb_unknown': 'не определено (нет root)',
    'up_adb_failed': 'Не удалось изменить (нет root?)',
    'rd_send': 'Отправить диагностику',
    'rd_sending': 'Собираю и отправляю…',
    'rd_last': 'Последний пакет',
    'rd_none': 'пакетов ещё не было',
    'rd_sent': 'отправлен',
    'rd_unsent': 'НЕ отправлен (ждёт связи)',
    'rd_commands': 'Последние команды',
    'rd_no_commands': 'команд ещё не было',
    'cloud_device_id': 'Номер аппарата',
    'cloud_url': 'Адрес сервера',
    'cloud_key': 'Публичный ключ (anon)',
    'cloud_token': 'Токен аппарата',
    'cloud_test': 'Проверить связь',
    'cloud_testing': 'Проверка…',
    'cloud_ok': 'Связь есть, событие отправлено',
    'cloud_fail': 'Связи нет — проверь адрес, ключ и токен',
    'cloud_hint':
        'Аппарат работает и без облака. Если выключено — события пишутся только в локальный журнал.',
    'cloud_sync_now': 'Синхронизировать сейчас',
    'cloud_synced': 'Синхронизация выполнена',
    'tab_kiosk': 'Киоск',
    'kiosk_enabled': 'Киоск-режим',
    'kiosk_hint':
        'После включения откроется системный экран выбора домашнего '
        'приложения — выберите там это приложение. Затем один раз нажмите '
        '«Домой» на планшете: если снова появится диалог выбора — обязательно '
        'выберите это приложение и нажмите «Всегда» (не «Только сейчас»), '
        'иначе автоматическое восстановление после сбоя не заработает. '
        'Device Owner и полное закрепление экрана (Lock Task) сюда не входят '
        '— это отдельный шаг перед сдачей аппарата.',
    'kiosk_open_desktop': 'Открыть системный рабочий стол',
    'kiosk_open_desktop_hint':
        'Нужно для обслуживания планшета, пока '
        'включён киоск-режим — без этой кнопки из приложения будет не выйти.',
    // --- Сканер шины (задача "сканер шины Modbus") ---
    'tab_scanner': 'Сканер',
    'scanner_scan_section': 'Поиск устройств',
    'scanner_scan_from': 'От',
    'scanner_scan_to': 'До',
    'scanner_scan_start': 'Начать поиск',
    'scanner_scan_stop': 'Остановить',
    'scanner_scan_progress': 'Опрошено',
    'scanner_scan_empty': 'Пока ничего не найдено',
    'scanner_scan_parity': 'Чётность (для этого поиска)',
    'scanner_parity_none': 'Нет',
    'scanner_parity_odd': 'Odd',
    'scanner_parity_even': 'Even',
    'scanner_known_dio': 'модуль входов-выходов',
    'scanner_known_thermo': 'термопары',
    'scanner_known_energy': 'счётчик энергии',
    'scanner_read_section': 'Чтение регистров',
    'scanner_slave': 'Адрес устройства',
    'scanner_func': 'Тип чтения',
    'scanner_func_coils': 'Катушки (FC01)',
    'scanner_func_discrete': 'Дискретные входы (FC02)',
    'scanner_func_holding': 'Регистры хранения (FC03)',
    'scanner_func_input': 'Входные регистры (FC04)',
    'scanner_start_addr': 'Начальный адрес',
    'scanner_count': 'Количество',
    'scanner_read_btn': 'Прочитать',
    'scanner_result_addr': 'Регистр',
    'scanner_result_dec': 'Десятичное',
    'scanner_result_hex': 'Hex',
    'scanner_result_signed': 'Знаковое',
    'scanner_bit_on': 'ВКЛ',
    'scanner_bit_off': 'ВЫКЛ',
    'scanner_err_no_response': 'Нет ответа',
    'scanner_err_bad_crc': 'Неверная контрольная сумма',
    'scanner_err_exception': 'Устройство вернуло код ошибки',
    'scanner_write_section': 'Запись регистра',
    'scanner_write_warning':
        'Опасно: неверная запись в служебный регистр способна сделать '
        'устройство недоступным — восстановление потребует подключения в одиночку.',
    'scanner_write_type': 'Тип записи',
    'scanner_write_type_register': 'Регистр (FC06)',
    'scanner_write_type_coil': 'Катушка (FC05)',
    'scanner_write_addr': 'Адрес регистра',
    'scanner_write_value': 'Значение',
    'scanner_write_btn': 'Записать',
    'scanner_write_confirm_title': 'Подтвердите запись',
    'scanner_write_confirm_cancel': 'Отмена',
    'scanner_write_result_readback': 'Перечитано',
    'scanner_write_result_fail': 'Запись не удалась',
    'scanner_fc15_section': 'Групповая запись катушек (FC15)',
    'scanner_fc15_warning':
        'Опасно: пишет несколько выходов одним кадром. Только выключение — '
        'при живой фазе и сухих насосах включение группой одним касанием '
        'невосстановимо, а нужного сценария для этого нет.',
    'scanner_fc15_off': 'Все ВЫКЛ (0)',
    'scanner_fc15_btn': 'Записать группой (FC15)',
    'scanner_fc15_ok': 'Принято',
    'scanner_fc16_section': 'Запись регистра группой (FC16)',
    'scanner_fc16_warning':
        'Для устройств без FC06 (например, счётчик энергии Chint DDSU666 — '
        'по документации только 03 на чтение и 16 на запись, даже для '
        'одного регистра). Одна попытка, без автоповторов.',
    'scanner_fc16_btn': 'Записать (FC16)',
    'scanner_clear': 'Очистить результаты',
    // --- Починка обмена по шине (задача "починить обмен по шине") ---
    'bus_healthy': 'Шина работает',
    'bus_unhealthy': 'Шина недоступна',
    'diag_port_busy': 'Порт занят другим процессом:',
    'watchdog_enabled': 'Сторож выходов',
    'watchdog_hint':
        'Периодически сверяет фактическое состояние выходов с ожидаемым '
        '"всё выключено" в покое; включённый выход гасит, а если он не '
        'гаснет — выводит аппарат из обслуживания. Включён по умолчанию.',
    'diag_devices_section': 'Устройства на шине',
    'diag_device_thermo': 'Термопара',
    'diag_device_energy': 'Счётчик энергии',
    'diag_device_coin': 'Монетоприёмник',
    'diag_simulate_coin_down': 'Имитировать отказ монетоприёмника',
    'diag_simulate_coin_down_hint':
        'Подделывает статус на аппарате, шину не трогает — для проверки доплаты картой и ухода в ошибку. Живёт до ручного выключения, но не дольше 30 минут (потом гаснет сам), переживает переход на экран оплаты — не забудьте выключить после теста.',
    'diag_freeze_temp': 'Заморозить показание температуры',
    'diag_freeze_temp_hint':
        'Отладка: термопара «залипает» на последнем значении, шину не читает — для проверки детекторов отказа датчика. Проверка идёт с ВКЛЮЧЁННЫМ ТЭНом: техник стоит рядом и готов отключить питание. Живёт до ручного выключения, автоснятие через 30 минут, видно в облаке.',
    'diag_freeze_temp_failed':
        'Заморозить нечем: нет ни одного чтения температуры',
    'oos_status_ok': 'Аппарат принимает оплату',
    'oos_status_cfg_blocked':
        'ОПЛАТА ЗАБЛОКИРОВАНА конфигурацией (это не отказ)',
    'oos_cfg_missing':
        'Не отмечены установленными (включите: Диагностика → Устройства на шине)',
    'oos_status_blocked': 'ВЫВЕДЕН ИЗ ОБСЛУЖИВАНИЯ — оплата заблокирована',
    'oos_reason': 'Причина',
    'oos_since': 'С',
    'oos_code_heater_no_power': 'отказ нагрева (ТЭН не дал мощности)',
    'oos_code_temp_sensor_fault':
        'отказ датчика температуры / убегающий нагрев',
    'oos_code_heat_timeout': 'прогрев не достиг цели за 180 с',
    'oos_code_heater_off_unconfirmed':
        'выключение ТЭНа не подтверждено (возможно, залипло реле)',
    'oos_code_overheat':
        'перегрев (ТЭН не выключается или не работает термостат)',
    'oos_code_output_stuck_on':
        'выход остаётся включённым после аварийного выключения',
    'oos_code_state_unreadable':
        'состояние не читается (fail-closed при старте)',
    'oos_trial_btn': 'Пробный цикл (без оплаты)',
    'oos_trial_running': 'Идёт пробный цикл…',
    'oos_trial_hint':
        'Греет ТЭН несколько секунд, проверяет мощность и рост температуры. Блокировку сам не снимает и оплату клиентам не открывает.',
    'oos_trial_pass':
        'Пробный цикл пройден — блокировку можно снять (15 минут)',
    'oos_trial_pass_healthy': 'Пробный цикл пройден',
    'oos_trial_fail': 'Пробный цикл провален',
    'oos_trial_too_hot': 'Испаритель горячий — подождите остывания',
    'oos_trial_busy': 'Пробный цикл сейчас недоступен',
    'oos_trial_abort': 'Прервать пробный цикл',
    'oos_trial_no_thermo':
        'Термопара не отмечена как установленная — пробный цикл невозможен',
    'oos_trial_cancelled': 'Пробный цикл прерван',
    'oos_clear_btn': 'Снять блокировку',
    'oos_clear_hint':
        'Только на месте и только после успешного пробного цикла. Удалённо снять нельзя.',
    'oos_clear_confirm_title': 'Снять блокировку?',
    'oos_clear_confirm_body':
        'Аппарат снова начнёт принимать оплату. Убедитесь, что неисправность устранена, а пробный цикл прошёл.',
    'oos_cleared': 'Блокировка снята',
    'oos_clear_failed':
        'Не удалось снять блокировку — пройдите пробный цикл заново',
    'diag_seconds_suffix': ' с',
    'diag_confirm_title': 'Подтвердите включение',
    'diag_confirm_body':
        'Нагрузка будет включена на реальном оборудовании и автоматически '
        'выключится через 10 секунд. Продолжить?',
    'diag_cold_start_btn': 'Проверить состояние после включения питания',
    'diag_cold_start_error': 'Не удалось прочитать состояние выходов',
    'diag_cold_start_ok': 'Все выходы выключены — состояние в норме',
    'diag_cold_start_fail': 'Внимание, выходы включены',
    'scanner_sweep_hint':
        'Устройство не отвечает ни на одном адресе на текущей скорости? '
        'Проверьте другие скорости — порт вернётся на рабочую скорость '
        'после проверки в любом случае.',
    'scanner_sweep_btn': 'Перебрать скорость (4800/19200/38400/115200)',
    'scanner_sweep_found': 'Найден на скорости',
    'scanner_sweep_not_found': 'Не найден ни на одной скорости',
    // --- Смена Slave ID (задача "смена Slave ID CWT-BK-1616T-S") ---
    'scanner_id_section': 'Смена Slave ID (CWT-BK-1616T-S)',
    'scanner_id_warning':
        'Опасно: процедура пишет служебные регистры устройства напрямую. '
        'Ошибка на середине способна оставить модуль в состоянии, которое '
        'потом трудно разобрать. Каждый шаг записывается в журнал ниже.',
    'scanner_id_old': 'Текущий адрес',
    'scanner_id_new': 'Новый адрес',
    'scanner_id_btn': 'Записать и сохранить',
    'scanner_id_confirm_title': 'Подтвердите смену адреса',
    'scanner_id_confirm_write': 'Записать адрес',
    'scanner_id_confirm_into': 'в устройство на адресе',
    'scanner_id_skip': 'Пропустить опознание',
    'scanner_id_skip_hint':
        'Только при замене модуля на экземпляр с другой прошивкой — '
        'сигнатура тогда не совпадёт с эталоном, хотя устройство настоящее. '
        'В остальных случаях не включать: без опознания запись может уйти '
        'в постороннее устройство на этом адресе.',
    'scanner_id_power_cycle_hint':
        'Снимите питание с модуля на 10 секунд, затем подайте обратно. '
        'Когда модуль перезапустится — нажмите «Продолжить проверку».',
    'scanner_id_verify_btn': 'Продолжить проверку',
    'scanner_id_cancel_wait': 'Отменить ожидание',
    'scanner_id_dump_title': 'Дамп 16 регистров после смены',
    'scanner_id_new_addr_confirmed': 'Новый адрес подтверждён чтением',
    'scanner_id_old_still_responds':
        'Старый адрес всё ещё отвечает — конфликт адресов на общей шине. '
        'Модуль, откликающийся на двух адресах, даст наложение кадров и '
        'плавающие ошибки CRC.',
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
    'err_price': 'Price: from 0.50 € to 20 €',
    'err_duration': 'Duration: 10–120 sec',
    'err_pin': 'PIN must be 4 digits',
    'err_pin_weak':
        'PIN is too simple: not 1234, repeated digits or a sequence',
    'mc_title': 'Master code (emergency access)',
    'mc_ack': 'Master code recorded',
    'mc_not_ack': 'Master code NOT recorded — commissioning is not finished',
    'mc_show': 'Show master code',
    'mc_change': 'Change master code',
    'mc_change_warn':
        'The previous master code will stop working. The new one is shown once. Continue?',
    'mc_shown_title': 'Master code of this machine',
    'mc_shown_warn':
        'Write the code down and keep it apart from the machine. It cannot be shown again.',
    'mc_written': 'I have written it down',
    'mc_close_unconfirmed': 'Close without confirming',
    'mc_hint':
        'The code is needed if the service PIN is forgotten. Every machine has its own.',
    'cancel_btn': 'Cancel',
    'compressor_purge_label':
        'Compressor purge before pumps/heater turn on (sec)',
    'pump_after_heater_label': 'Pump run time after heater turns off (sec)',
    'err_compressor_purge': 'Compressor purge: 0–60 sec',
    'err_pump_after_heater': 'Pump after heater: 0–60 sec',
    'tariff_label': 'Electricity tariff (€/kWh)',
    'err_tariff': 'Tariff: non-negative number',
    'idle_cost_label': 'Daily idle cost (reference only)',
    'available': 'OK',
    'empty_level': 'Empty',
    'flavor_fallback': 'Fragrance',
    'coin_label': 'Coin',
    'coin_yes': 'YES',
    'coin_no': 'NO',
    'temp_label': 'Temperature',
    'temp_unavailable': '--',
    'not_installed': 'not installed',
    'diag_levels': 'Canister levels',
    'diag_manual': 'Manual control',
    'diag_manual_warning':
        'Caution: direct hardware control, bypassing normal machine logic',
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
    'terminal_section': 'Payment terminal',
    'terminal_enabled': 'Terminal connected',
    'terminal_channel': 'DI channel',
    'terminal_mode': 'Detection mode',
    'terminal_mode_edge': 'Edge (short pulse)',
    'terminal_mode_level': 'Level (held during transaction)',
    'terminal_guard': 'Guard delay (ms)',
    'terminal_state': 'Input now',
    'terminal_state_high': 'HIGH',
    'terminal_state_low': 'LOW',
    'terminal_state_unknown': '—',
    'terminal_observe_start': 'Start observing',
    'terminal_observe_stop': 'Stop observing',
    'terminal_journal': 'Signal log',
    'terminal_journal_clear': 'Clear log',
    'terminal_journal_empty':
        'Empty so far — start observing and tap a card on the terminal',
    'err_terminal_channel': 'Channel: 0–15',
    'err_terminal_guard': 'Guard delay: 100 ms minimum',
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
    'last_cycle_voltage': 'Grid voltage (last cycle)',
    'unit_kwh': 'kWh',
    'tab_cloud': 'Cloud',
    'cloud_enabled': 'Send data to the cloud',
    'rd_title': 'Remote diagnostics',
    'up_title': 'App update',
    'up_version': 'Version',
    'up_backup': 'Backup version',
    'up_backup_none': 'none (appears after the first update)',
    'up_last': 'Last update',
    'up_last_none': 'none yet',
    'up_rollback': 'Roll back',
    'up_rollback_title': 'Roll back to the backup version?',
    'up_rollback_body':
        'The app will be replaced by the backup version and restarted. Machine data is not erased. Payments are not accepted during the rollback.',
    'up_rollback_started': 'Rollback started',
    'up_rollback_failed': 'Rollback not started',
    'up_adb': 'ADB over network: keep after reboot',
    'up_adb_warn':
        'Anyone on the same network as the tablet will be able to connect to it over ADB. Enable only during maintenance and on a trusted network. Enable?',
    'up_adb_state': 'ADB over network state',
    'up_adb_unknown': 'unknown (no root)',
    'up_adb_failed': 'Could not change (no root?)',
    'rd_send': 'Send diagnostics',
    'rd_sending': 'Collecting and sending…',
    'rd_last': 'Last bundle',
    'rd_none': 'no bundles yet',
    'rd_sent': 'sent',
    'rd_unsent': 'NOT sent (waiting for connection)',
    'rd_commands': 'Last commands',
    'rd_no_commands': 'no commands yet',
    'cloud_device_id': 'Device ID',
    'cloud_url': 'Server URL',
    'cloud_key': 'Public key (anon)',
    'cloud_token': 'Device token',
    'cloud_test': 'Test connection',
    'cloud_testing': 'Testing…',
    'cloud_ok': 'Connected, test event sent',
    'cloud_fail': 'No connection — check URL, key and token',
    'cloud_hint':
        'The machine works without the cloud. When disabled, events are stored in the local log only.',
    'cloud_sync_now': 'Sync now',
    'cloud_synced': 'Sync complete',
    'tab_kiosk': 'Kiosk',
    'kiosk_enabled': 'Kiosk mode',
    'kiosk_hint':
        'Once enabled, a system screen opens to pick the default '
        'home app — choose this app there. Then press "Home" once on the '
        'tablet: if a chooser dialog appears again, pick this app and choose '
        '"Always" (not "Just once") — otherwise automatic recovery after a '
        'crash will not work. Device Owner and full screen pinning (Lock '
        'Task) are not part of this — that is a separate step right before '
        'handover.',
    'kiosk_open_desktop': 'Open system desktop',
    'kiosk_open_desktop_hint':
        'Needed to service the tablet while kiosk '
        'mode is on — without this button there is no way out of the app.',
    // --- Bus scanner ---
    'tab_scanner': 'Scanner',
    'scanner_scan_section': 'Device search',
    'scanner_scan_from': 'From',
    'scanner_scan_to': 'To',
    'scanner_scan_start': 'Start search',
    'scanner_scan_stop': 'Stop',
    'scanner_scan_progress': 'Probed',
    'scanner_scan_empty': 'Nothing found yet',
    'scanner_scan_parity': 'Parity (for this search)',
    'scanner_parity_none': 'None',
    'scanner_parity_odd': 'Odd',
    'scanner_parity_even': 'Even',
    'scanner_known_dio': 'I/O module',
    'scanner_known_thermo': 'thermocouples',
    'scanner_known_energy': 'energy meter',
    'scanner_read_section': 'Register read',
    'scanner_slave': 'Device address',
    'scanner_func': 'Read type',
    'scanner_func_coils': 'Coils (FC01)',
    'scanner_func_discrete': 'Discrete inputs (FC02)',
    'scanner_func_holding': 'Holding registers (FC03)',
    'scanner_func_input': 'Input registers (FC04)',
    'scanner_start_addr': 'Start address',
    'scanner_count': 'Count',
    'scanner_read_btn': 'Read',
    'scanner_result_addr': 'Register',
    'scanner_result_dec': 'Decimal',
    'scanner_result_hex': 'Hex',
    'scanner_result_signed': 'Signed',
    'scanner_bit_on': 'ON',
    'scanner_bit_off': 'OFF',
    'scanner_err_no_response': 'No response',
    'scanner_err_bad_crc': 'Bad checksum',
    'scanner_err_exception': 'Device returned an error code',
    'scanner_write_section': 'Register write',
    'scanner_write_warning':
        'Dangerous: a wrong write to a service register can make the '
        'device unreachable — recovery will need a one-on-one connection.',
    'scanner_write_type': 'Write type',
    'scanner_write_type_register': 'Register (FC06)',
    'scanner_write_type_coil': 'Coil (FC05)',
    'scanner_write_addr': 'Register address',
    'scanner_write_value': 'Value',
    'scanner_write_btn': 'Write',
    'scanner_write_confirm_title': 'Confirm write',
    'scanner_write_confirm_cancel': 'Cancel',
    'scanner_write_result_readback': 'Read back',
    'scanner_write_result_fail': 'Write failed',
    'scanner_fc15_section': 'Group coil write (FC15)',
    'scanner_fc15_warning':
        'Danger: writes several outputs in one frame. Off only — with live '
        'phase power and dry pumps, a group turn-on from one tap is '
        'unrecoverable, and there is no scenario that needs it.',
    'scanner_fc15_off': 'All OFF (0)',
    'scanner_fc15_btn': 'Write group (FC15)',
    'scanner_fc15_ok': 'Accepted',
    'scanner_fc16_section': 'Group register write (FC16)',
    'scanner_fc16_warning':
        'For devices without FC06 (e.g. the Chint DDSU666 energy meter — '
        'per its manual only 03 read and 16 write, even for one register). '
        'One attempt, no auto-retry.',
    'scanner_fc16_btn': 'Write (FC16)',
    'scanner_clear': 'Clear results',
    // --- Bus exchange fix ---
    'bus_healthy': 'Bus is working',
    'bus_unhealthy': 'Bus unavailable',
    'diag_port_busy': 'Port occupied by another process:',
    'watchdog_enabled': 'Output watchdog',
    'watchdog_hint':
        'Periodically checks that outputs are actually off while idle; '
        'switches off any output found on and, if it will not switch off, '
        'takes the machine out of service. On by default.',
    'diag_devices_section': 'Devices on the bus',
    'diag_device_thermo': 'Thermocouple',
    'diag_device_energy': 'Energy meter',
    'diag_device_coin': 'Coin acceptor',
    'diag_simulate_coin_down': 'Simulate coin acceptor failure',
    'diag_simulate_coin_down_hint':
        'Fakes the status on the device, never touches the bus — for testing the card top-up and error branches. Stays on until switched off, but no longer than 30 minutes (then switches itself off), survives leaving for the payment screen — remember to turn it off after testing.',
    'diag_freeze_temp': 'Freeze temperature reading',
    'diag_freeze_temp_hint':
        'Debug: the thermocouple "sticks" at its last value, the bus is not read — for testing the sensor-fault detectors. The test runs with the heater ON: the technician stays next to the machine ready to cut power. Stays on until switched off, auto-off after 30 minutes, visible in the cloud.',
    'diag_freeze_temp_failed': 'Nothing to freeze: no temperature reading yet',
    'oos_status_ok': 'Machine is accepting payments',
    'oos_status_cfg_blocked': 'PAYMENT BLOCKED by configuration (not a fault)',
    'oos_cfg_missing':
        'Not marked as installed (enable: Diagnostics → Devices on the bus)',
    'oos_status_blocked': 'OUT OF SERVICE — payments blocked',
    'oos_reason': 'Reason',
    'oos_since': 'Since',
    'oos_code_heater_no_power': 'heater failure (no heater power)',
    'oos_code_temp_sensor_fault': 'temperature sensor fault / runaway heating',
    'oos_code_heat_timeout': 'preheat did not reach the target in 180 s',
    'oos_code_heater_off_unconfirmed':
        'heater switch-off not confirmed (relay may be stuck)',
    'oos_code_overheat':
        'overheating (heater does not switch off or thermostat failed)',
    'oos_code_output_stuck_on': 'an output stays on after emergency switch-off',
    'oos_code_state_unreadable': 'state unreadable (fail-closed at startup)',
    'oos_trial_btn': 'Trial cycle (no payment)',
    'oos_trial_running': 'Trial cycle running…',
    'oos_trial_hint':
        'Heats for a few seconds and checks heater power and temperature rise. Does not lift the block by itself and does not open payments to customers.',
    'oos_trial_pass':
        'Trial cycle passed — the block can be lifted (15 minutes)',
    'oos_trial_pass_healthy': 'Trial cycle passed',
    'oos_trial_fail': 'Trial cycle failed',
    'oos_trial_too_hot': 'Evaporator is hot — wait for it to cool',
    'oos_trial_busy': 'Trial cycle is not available right now',
    'oos_trial_abort': 'Abort trial cycle',
    'oos_trial_no_thermo':
        'Thermocouple is not marked as installed — trial cycle is not possible',
    'oos_trial_cancelled': 'Trial cycle interrupted',
    'oos_clear_btn': 'Lift the block',
    'oos_clear_hint':
        'On site only, and only after a successful trial cycle. It cannot be lifted remotely.',
    'oos_clear_confirm_title': 'Lift the block?',
    'oos_clear_confirm_body':
        'The machine will start accepting payments again. Make sure the fault is fixed and the trial cycle passed.',
    'oos_cleared': 'Block lifted',
    'oos_clear_failed': 'Could not lift the block — run the trial cycle again',
    'diag_seconds_suffix': ' s',
    'diag_confirm_title': 'Confirm activation',
    'diag_confirm_body':
        'This load will be switched on on real hardware and will '
        'automatically switch off after 10 seconds. Continue?',
    'diag_cold_start_btn': 'Check state after power-on',
    'diag_cold_start_error': 'Failed to read output state',
    'diag_cold_start_ok': 'All outputs are off — state is normal',
    'diag_cold_start_fail': 'Warning: outputs are on',
    'scanner_sweep_hint':
        'Device not answering on any address at the current baud rate? '
        'Try other baud rates — the port returns to the working rate '
        'after the check either way.',
    'scanner_sweep_btn': 'Sweep baud rate (4800/19200/38400/115200)',
    'scanner_sweep_found': 'Found at baud',
    'scanner_sweep_not_found': 'Not found at any baud rate',
    // --- Change Slave ID (CWT-BK-1616T-S) ---
    'scanner_id_section': 'Change Slave ID (CWT-BK-1616T-S)',
    'scanner_id_warning':
        'Dangerous: this writes the device\'s service registers directly. '
        'A failure midway can leave the module in a state that is hard to '
        'recover. Every step is written to the log below.',
    'scanner_id_old': 'Current address',
    'scanner_id_new': 'New address',
    'scanner_id_btn': 'Write and save',
    'scanner_id_confirm_title': 'Confirm address change',
    'scanner_id_confirm_write': 'Write address',
    'scanner_id_confirm_into': 'into the device at address',
    'scanner_id_skip': 'Skip identification',
    'scanner_id_skip_hint':
        'Only when replacing the module with a unit running different '
        'firmware — its signature will then not match the reference even '
        'though the device is genuine. Otherwise leave off: without '
        'identification the write can land on an unrelated device at this '
        'address.',
    'scanner_id_power_cycle_hint':
        'Power off the module for 10 seconds, then power it back on. Once '
        'the module has restarted, tap "Continue check".',
    'scanner_id_verify_btn': 'Continue check',
    'scanner_id_cancel_wait': 'Cancel waiting',
    'scanner_id_dump_title': 'Dump of 16 registers after the change',
    'scanner_id_new_addr_confirmed': 'New address confirmed by reading',
    'scanner_id_old_still_responds':
        'The old address still responds — address conflict on the shared '
        'bus. A module answering on two addresses will cause frame overlap '
        'and intermittent CRC errors.',
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
    'err_price': 'Hind: 0.50 € kuni 20 €',
    'err_duration': 'Kestus: 10–120 sek',
    'err_pin': 'PIN peab olema 4 numbrit',
    'err_pin_weak':
        'PIN on liiga lihtne: mitte 1234, samad numbrid ega järjestus',
    'mc_title': 'Peakood (avariijuurdepääs)',
    'mc_ack': 'Peakood on üles kirjutatud',
    'mc_not_ack':
        'Peakoodi POLE üles kirjutatud — kasutuselevõtt pole lõpetatud',
    'mc_show': 'Näita peakoodi',
    'mc_change': 'Muuda peakoodi',
    'mc_change_warn':
        'Eelmine peakood lakkab kehtimast. Uus näidatakse ainult üks kord. Jätka?',
    'mc_shown_title': 'Selle seadme peakood',
    'mc_shown_warn':
        'Kirjuta kood üles ja hoia seadmest eraldi. Uuesti näidata ei saa.',
    'mc_written': 'Kirjutasin üles',
    'mc_close_unconfirmed': 'Sulge kinnitamata',
    'mc_hint': 'Kood on vaja, kui teenindus-PIN ununeb. Igal seadmel on oma.',
    'cancel_btn': 'Tühista',
    'compressor_purge_label':
        'Kompressori puhastus enne pumpade/küttekeha sisselülitamist (sek)',
    'pump_after_heater_label':
        'Pumba töö pärast küttekeha väljalülitamist (sek)',
    'err_compressor_purge': 'Kompressori puhastus: 0–60 sek',
    'err_pump_after_heater': 'Pump pärast küttekeha: 0–60 sek',
    'tariff_label': 'Elektritariif (€/kWh)',
    'err_tariff': 'Tariif: mittenegatiivne arv',
    'idle_cost_label': 'Seisaku maksumus ööpäevas (info)',
    'available': 'Olemas',
    'empty_level': 'Tühi',
    'coin_label': 'Münt',
    'coin_yes': 'JAH',
    'coin_no': 'EI',
    'temp_label': 'Temperatuur',
    'temp_unavailable': '--',
    'not_installed': 'paigaldamata',
    'flavor_fallback': 'Lõhn',
    'diag_levels': 'Kanistrite tasemed',
    'diag_manual': 'Käsijuhtimine',
    'diag_manual_warning':
        'Ettevaatust: seadmete otsejuhtimine, mööda tavapärasest töölogikast',
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
    'terminal_section': 'Maksepterminal',
    'terminal_enabled': 'Terminal ühendatud',
    'terminal_channel': 'DI kanal',
    'terminal_mode': 'Tuvastusrežiim',
    'terminal_mode_edge': 'Fronditi (lühiimpulss)',
    'terminal_mode_level': 'Taseme järgi (hoitakse tehingu ajal)',
    'terminal_guard': 'Kaitsepaus (ms)',
    'terminal_state': 'Sisend praegu',
    'terminal_state_high': 'KÕRGE',
    'terminal_state_low': 'MADAL',
    'terminal_state_unknown': '—',
    'terminal_observe_start': 'Alusta jälgimist',
    'terminal_observe_stop': 'Peata jälgimine',
    'terminal_journal': 'Signaali logi',
    'terminal_journal_clear': 'Tühjenda logi',
    'terminal_journal_empty':
        'Veel tühi — alusta jälgimist ja puuduta kaardiga terminali',
    'err_terminal_channel': 'Kanal: 0–15',
    'err_terminal_guard': 'Kaitsepaus: vähemalt 100 ms',
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
    'last_cycle_voltage': 'Võrgupinge (viimane tsükkel)',
    'unit_kwh': 'kWh',
    'tab_cloud': 'Pilv',
    'cloud_enabled': 'Saada andmed pilve',
    'rd_title': 'Kaugdiagnostika',
    'up_title': 'Rakenduse uuendus',
    'up_version': 'Versioon',
    'up_backup': 'Varuversioon',
    'up_backup_none': 'puudub (ilmub pärast esimest uuendust)',
    'up_last': 'Viimane uuendus',
    'up_last_none': 'pole veel olnud',
    'up_rollback': 'Taasta eelmine',
    'up_rollback_title': 'Taasta varuversioon?',
    'up_rollback_body':
        'Rakendus asendatakse varuversiooniga ja käivitatakse uuesti. Seadme andmeid ei kustutata. Tagasivõtmise ajal makseid ei võeta vastu.',
    'up_rollback_started': 'Tagasivõtmine alustatud',
    'up_rollback_failed': 'Tagasivõtmist ei alustatud',
    'up_adb': 'ADB üle võrgu: säilita pärast taaskäivitust',
    'up_adb_warn':
        'Igaüks, kes on tahvliga samas võrgus, saab sellega ADB kaudu ühenduda. Lülita sisse ainult hoolduse ajaks ja usaldusväärses võrgus. Lülita sisse?',
    'up_adb_state': 'ADB üle võrgu olek',
    'up_adb_unknown': 'teadmata (puudub root)',
    'up_adb_failed': 'Muutmine ebaõnnestus (root puudub?)',
    'rd_send': 'Saada diagnostika',
    'rd_sending': 'Kogun ja saadan…',
    'rd_last': 'Viimane pakett',
    'rd_none': 'pakette pole veel',
    'rd_sent': 'saadetud',
    'rd_unsent': 'POLE saadetud (ootab ühendust)',
    'rd_commands': 'Viimased käsud',
    'rd_no_commands': 'käske pole veel',
    'cloud_device_id': 'Seadme number',
    'cloud_url': 'Serveri aadress',
    'cloud_key': 'Avalik võti (anon)',
    'cloud_token': 'Seadme luba',
    'cloud_test': 'Kontrolli ühendust',
    'cloud_testing': 'Kontrollin…',
    'cloud_ok': 'Ühendus olemas, sündmus saadetud',
    'cloud_fail': 'Ühendust pole — kontrolli aadressi, võtit ja luba',
    'cloud_hint':
        'Seade töötab ka ilma pilveta. Väljalülitatuna salvestatakse sündmused ainult kohalikku logisse.',
    'cloud_sync_now': 'Sünkroniseeri kohe',
    'cloud_synced': 'Sünkroniseerimine tehtud',
    'tab_kiosk': 'Kiosk',
    'kiosk_enabled': 'Kioski režiim',
    'kiosk_hint':
        'Sisselülitamisel avaneb süsteemi vaikimisi avakuva valiku '
        'ekraan — vali seal see rakendus. Seejärel vajuta tahvlil üks kord '
        '"Avakuva": kui ilmub uuesti valikudialoog, vali kindlasti see '
        'rakendus ja "Alati" (mitte "Ainult praegu") — vastasel juhul ei '
        'tööta automaatne taastumine pärast avariid. Device Owner ja '
        'täielik ekraani kinnitamine (Lock Task) siia ei kuulu — see on '
        'eraldi samm vahetult enne seadme üleandmist.',
    'kiosk_open_desktop': 'Ava süsteemi töölaud',
    'kiosk_open_desktop_hint':
        'Vajalik tahvli hooldamiseks, kui kioski '
        'režiim on sees — ilma selle nuputa ei pääse rakendusest välja.',
    // --- Siini skanner ---
    'tab_scanner': 'Skanner',
    'scanner_scan_section': 'Seadmete otsing',
    'scanner_scan_from': 'Alates',
    'scanner_scan_to': 'Kuni',
    'scanner_scan_start': 'Alusta otsingut',
    'scanner_scan_stop': 'Peata',
    'scanner_scan_progress': 'Kontrollitud',
    'scanner_scan_empty': 'Veel midagi ei leitud',
    'scanner_scan_parity': 'Paarsus (selle otsingu jaoks)',
    'scanner_parity_none': 'Puudub',
    'scanner_parity_odd': 'Odd',
    'scanner_parity_even': 'Even',
    'scanner_known_dio': 'sisend-väljundmoodul',
    'scanner_known_thermo': 'termopaarid',
    'scanner_known_energy': 'energiaarvesti',
    'scanner_read_section': 'Registrite lugemine',
    'scanner_slave': 'Seadme aadress',
    'scanner_func': 'Lugemise tüüp',
    'scanner_func_coils': 'Releed (FC01)',
    'scanner_func_discrete': 'Diskreetsed sisendid (FC02)',
    'scanner_func_holding': 'Hoiuregistrid (FC03)',
    'scanner_func_input': 'Sisendregistrid (FC04)',
    'scanner_start_addr': 'Algusaadress',
    'scanner_count': 'Kogus',
    'scanner_read_btn': 'Loe',
    'scanner_result_addr': 'Register',
    'scanner_result_dec': 'Kümnend',
    'scanner_result_hex': 'Hex',
    'scanner_result_signed': 'Märgiga',
    'scanner_bit_on': 'SEES',
    'scanner_bit_off': 'VÄLJAS',
    'scanner_err_no_response': 'Vastus puudub',
    'scanner_err_bad_crc': 'Vigane kontrollsumma',
    'scanner_err_exception': 'Seade tagastas veakoodi',
    'scanner_write_section': 'Registri kirjutamine',
    'scanner_write_warning':
        'Ohtlik: vale kirje teenindusregistrisse võib muuta seadme '
        'kättesaamatuks — taastamine nõuab ühendust seadmega üksinda.',
    'scanner_write_type': 'Kirjutamise tüüp',
    'scanner_write_type_register': 'Register (FC06)',
    'scanner_write_type_coil': 'Relee (FC05)',
    'scanner_write_addr': 'Registri aadress',
    'scanner_write_value': 'Väärtus',
    'scanner_write_btn': 'Kirjuta',
    'scanner_write_confirm_title': 'Kinnita kirjutamine',
    'scanner_write_confirm_cancel': 'Tühista',
    'scanner_write_result_readback': 'Tagasi loetud',
    'scanner_write_result_fail': 'Kirjutamine ebaõnnestus',
    'scanner_fc15_section': 'Mitme väljundi korraga kirjutamine (FC15)',
    'scanner_fc15_warning':
        'Ohtlik: kirjutab mitu väljundit ühe kaadriga. Ainult väljalülitus — '
        'reaalse faasipingega ja kuivade pumpadega oleks grupi sisselülitus '
        'ühe puudutusega parandamatu, ja seda vajavat stsenaariumi pole.',
    'scanner_fc15_off': 'Kõik VÄLJAS (0)',
    'scanner_fc15_btn': 'Kirjuta grupina (FC15)',
    'scanner_fc15_ok': 'Vastu võetud',
    'scanner_fc16_section': 'Registri kirjutamine grupina (FC16)',
    'scanner_fc16_warning':
        'Seadmetele, millel pole FC06 (nt Chint DDSU666 energiaarvesti — '
        'juhendi järgi ainult 03 lugemiseks ja 16 kirjutamiseks, isegi ühe '
        'registri jaoks). Üks katse, ilma automaatse korduseta.',
    'scanner_fc16_btn': 'Kirjuta (FC16)',
    'scanner_clear': 'Tühjenda tulemused',
    // --- Siiniühenduse parandus ---
    'bus_healthy': 'Siin töötab',
    'bus_unhealthy': 'Siin pole saadaval',
    'diag_port_busy': 'Port on hõivatud teise protsessi poolt:',
    'watchdog_enabled': 'Väljundite valvur',
    'watchdog_hint':
        'Kontrollib perioodiliselt, kas väljundid on puhkeolekus välja '
        'lülitatud; sisselülitatud väljundi lülitab välja ja kui see ei '
        'lülitu, võtab seadme hooldusest välja. Vaikimisi sees.',
    'diag_devices_section': 'Seadmed siinil',
    'diag_device_thermo': 'Termopaar',
    'diag_device_energy': 'Energiaarvesti',
    'diag_device_coin': 'Mündivastuvõtja',
    'diag_simulate_coin_down': 'Simuleeri mündivastuvõtja riket',
    'diag_simulate_coin_down_hint':
        'Võltsib oleku seadmes, siini ei puuduta — kaardiga juurdemaksu ja veaharu testimiseks. Püsib sees, kuni lülitad käsitsi välja, kuid mitte kauem kui 30 minutit (siis lülitub ise välja); jääb aktiivseks ka maksekuvale minnes — ära unusta pärast testimist välja lülitada.',
    'diag_freeze_temp': 'Külmuta temperatuurinäit',
    'diag_freeze_temp_hint':
        'Silumine: termopaar «kleepub» viimase väärtuse külge, siini ei loeta — anduririkke tuvastajate testimiseks. Test käib SISSELÜLITATUD küttekehaga: tehnik seisab kõrval ja on valmis toite katkestama. Püsib sees kuni käsitsi väljalülitamiseni, 30 minuti pärast lülitub ise välja, nähtav pilves.',
    'diag_freeze_temp_failed':
        'Pole mida külmutada: temperatuuri pole veel loetud',
    'oos_status_ok': 'Seade võtab makseid vastu',
    'oos_status_cfg_blocked':
        'MAKSED BLOKEERITUD seadistusega (see ei ole rike)',
    'oos_cfg_missing':
        'Pole paigaldatuks märgitud (lülita sisse: Diagnostika → Siini seadmed)',
    'oos_status_blocked': 'HOOLDUSEST VÄLJAS — maksed blokeeritud',
    'oos_reason': 'Põhjus',
    'oos_since': 'Alates',
    'oos_code_heater_no_power': 'kütte rike (küttekeha ei andnud võimsust)',
    'oos_code_temp_sensor_fault':
        'temperatuuriandurite rike / kontrollimatu kuumutamine',
    'oos_code_heat_timeout': 'eelsoojendus ei saavutanud sihti 180 s jooksul',
    'oos_code_heater_off_unconfirmed':
        'küttekeha väljalülitust ei kinnitatud (relee võib olla kinni)',
    'oos_code_overheat':
        'ülekuumenemine (küttekeha ei lülitu välja või termostaat ei tööta)',
    'oos_code_output_stuck_on': 'väljund jääb pärast avariilülitust sisse',
    'oos_code_state_unreadable': 'olek ei ole loetav (fail-closed käivitusel)',
    'oos_trial_btn': 'Prooviring (ilma makseta)',
    'oos_trial_running': 'Prooviring käib…',
    'oos_trial_hint':
        'Kuumutab paar sekundit, kontrollib küttekeha võimsust ja temperatuuri tõusu. Blokeeringut ise ei eemalda ega ava kliendile makseid.',
    'oos_trial_pass':
        'Prooviring läbitud — blokeeringu võib eemaldada (15 minutit)',
    'oos_trial_pass_healthy': 'Prooviring läbitud',
    'oos_trial_fail': 'Prooviring ebaõnnestus',
    'oos_trial_too_hot': 'Aurusti on kuum — oota jahtumist',
    'oos_trial_busy': 'Prooviring ei ole praegu saadaval',
    'oos_trial_abort': 'Katkesta prooviring',
    'oos_trial_no_thermo':
        'Termopaari ei ole paigaldatuks märgitud — prooviring pole võimalik',
    'oos_trial_cancelled': 'Prooviring katkestati',
    'oos_clear_btn': 'Eemalda blokeering',
    'oos_clear_hint':
        'Ainult kohapeal ja ainult pärast edukat proovirinki. Kaugelt eemaldada ei saa.',
    'oos_clear_confirm_title': 'Eemalda blokeering?',
    'oos_clear_confirm_body':
        'Seade hakkab taas makseid vastu võtma. Veendu, et rike on kõrvaldatud ja prooviring läbitud.',
    'oos_cleared': 'Blokeering eemaldatud',
    'oos_clear_failed':
        'Blokeeringut ei õnnestunud eemaldada — tee prooviring uuesti',
    'diag_seconds_suffix': ' s',
    'diag_confirm_title': 'Kinnita sisselülitamine',
    'diag_confirm_body':
        'Koormus lülitatakse sisse pärisseadmel ja lülitub automaatselt '
        'välja 10 sekundi pärast. Jätkata?',
    'diag_cold_start_btn': 'Kontrolli olekut pärast sisselülitamist',
    'diag_cold_start_error': 'Väljundite oleku lugemine ebaõnnestus',
    'diag_cold_start_ok': 'Kõik väljundid väljas — olek on korras',
    'diag_cold_start_fail': 'Tähelepanu, väljundid on sees',
    'scanner_sweep_hint':
        'Seade ei vasta ühelegi aadressile praegusel kiirusel? Proovi '
        'teisi kiirusi — port taastub töökiirusele igal juhul pärast '
        'kontrolli.',
    'scanner_sweep_btn': 'Proovi kiirusi (4800/19200/38400/115200)',
    'scanner_sweep_found': 'Leitud kiirusel',
    'scanner_sweep_not_found': 'Ei leitud ühelgi kiirusel',
    // --- Slave ID muutmine (CWT-BK-1616T-S) ---
    'scanner_id_section': 'Slave ID muutmine (CWT-BK-1616T-S)',
    'scanner_id_warning':
        'Ohtlik: protseduur kirjutab otse seadme teenindusregistritesse. '
        'Viga poole peal võib jätta mooduli olekusse, mida on hiljem raske '
        'lahti harutada. Iga samm kirjutatakse allolevasse logisse.',
    'scanner_id_old': 'Praegune aadress',
    'scanner_id_new': 'Uus aadress',
    'scanner_id_btn': 'Kirjuta ja salvesta',
    'scanner_id_confirm_title': 'Kinnita aadressi muutmine',
    'scanner_id_confirm_write': 'Kirjuta aadress',
    'scanner_id_confirm_into': 'seadmesse aadressil',
    'scanner_id_skip': 'Jäta tuvastus vahele',
    'scanner_id_skip_hint':
        'Ainult mooduli asendamisel teise firmware\'iga eksemplariga — '
        'selle signatuur ei lange siis etaloniga kokku, kuigi seade on '
        'ehtne. Muidu jäta välja lülitatuks: ilma tuvastuseta võib '
        'kirjutamine sattuda sellel aadressil olevasse võõrasse seadmesse.',
    'scanner_id_power_cycle_hint':
        'Lülita moodul 10 sekundiks vooluvõrgust välja, seejärel lülita '
        'uuesti sisse. Kui moodul on taaskäivitunud, vajuta "Jätka '
        'kontrolli".',
    'scanner_id_verify_btn': 'Jätka kontrolli',
    'scanner_id_cancel_wait': 'Tühista ootamine',
    'scanner_id_dump_title': 'Vahetusjärgne tõmmis (16 registrit)',
    'scanner_id_new_addr_confirmed': 'Uus aadress kinnitatud lugemisega',
    'scanner_id_old_still_responds':
        'Vana aadress vastab endiselt — aadresside konflikt ühisel siinil. '
        'Kahel aadressil vastav moodul põhjustab kaadrite kattumist ja '
        'ajuti tekkivaid CRC vigu.',
  },
};

class ServiceMenuScreen extends StatefulWidget {
  const ServiceMenuScreen({super.key});

  @override
  State<ServiceMenuScreen> createState() => _ServiceMenuScreenState();
}

class _ServiceMenuScreenState extends State<ServiceMenuScreen> {
  int _tab =
      0; // 0=Настройки, 1=Ароматы, 2=Диагностика, 3=Датчики, 4=Журнал, 5=Облако, 6=Сканер, 7=Киоск

  Widget _buildTab() {
    switch (_tab) {
      case 0:
        return _SettingsTab();
      case 1:
        return _FlavorsTab();
      case 2:
        return _DiagnosticsTab();
      case 3:
        return _SensorsTab();
      case 4:
        return _JournalTab();
      case 5:
        return _CloudTab();
      case 6:
        return _ScannerTab();
      default:
        return _KioskTab();
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
      t['tab_cloud']!,
      t['tab_scanner']!,
      t['tab_kiosk']!,
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
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: List.generate(tabs.length, (i) {
                  final active = _tab == i;
                  return GestureDetector(
                    onTap: () => setState(() => _tab = i),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        vertical: 12,
                        horizontal: 18,
                      ),
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
                  );
                }),
              ),
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
  late TextEditingController _tariffCtrl;

  @override
  void initState() {
    super.initState();
    unawaited(_loadMasterState());
    final config = context.read<AppNotifier>().config;
    _priceCents = config.treatmentPriceCents;
    _durationCtrl = TextEditingController(
      text: config.treatmentDurationS.toString(),
    );
    _pinCtrl = TextEditingController(text: config.servicePin);
    _compressorPurgeCtrl = TextEditingController(
      text: config.compressorPurgeS.toString(),
    );
    _pumpAfterHeaterCtrl = TextEditingController(
      text: config.pumpAfterHeaterS.toString(),
    );
    _tariffCtrl = TextEditingController(
      text: config.idlePowerTariffPerKwh.toStringAsFixed(2),
    )..addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _durationCtrl.dispose();
    _pinCtrl.dispose();
    _compressorPurgeCtrl.dispose();
    _pumpAfterHeaterCtrl.dispose();
    _tariffCtrl.dispose();
    super.dispose();
  }

  // Справочная строка (задача "контроль цикла по электросчётчику", фаза 2,
  // часть 3) — НЕ аналитика, просто перевод известной константы холостого
  // хода в деньги по редактируемому тарифу, пересчитывается на лету по
  // полю ввода. PowerSignature.idleW — ПОДТВЕРЖДЕНО замером 29.09.2026.
  double get _dailyIdleCostEur {
    final tariff = double.tryParse(_tariffCtrl.text.replaceAll(',', '.'));
    if (tariff == null) return 0;
    final dailyKwh = PowerSignature.idleW * 24 / 1000;
    return dailyKwh * tariff;
  }

  void _changePrice(int deltaCents) {
    setState(() {
      _priceCents = (_priceCents + deltaCents).clamp(
        ConfigLimits.priceMinCents,
        ConfigLimits.priceMaxCents,
      );
    });
  }

  void _save() {
    final notifier = context.read<AppNotifier>();
    final t = _i18n[notifier.lang]!;
    final duration = int.tryParse(_durationCtrl.text);
    final pin = _pinCtrl.text.trim();
    final compressorPurge = int.tryParse(_compressorPurgeCtrl.text);
    final pumpAfterHeater = int.tryParse(_pumpAfterHeaterCtrl.text);

    if (_priceCents < ConfigLimits.priceMinCents ||
        _priceCents > ConfigLimits.priceMaxCents) {
      _snack(t['err_price']!);
      return;
    }
    if (duration == null ||
        duration < ConfigLimits.treatmentDurationMinS ||
        duration > ConfigLimits.treatmentDurationMaxS) {
      _snack(t['err_duration']!);
      return;
    }
    if (pin.length != 4 || int.tryParse(pin) == null) {
      _snack(t['err_pin']!);
      return;
    }
    // Слабый PIN (1234, одинаковые цифры, подряд…) — нельзя. Если PIN в
    // поле не менялся и сейчас уже установлен прежний, он тоже должен
    // проходить правила (иначе "1234" остался бы навсегда).
    if (PinPolicy.isWeak(pin)) {
      _snack(t['err_pin_weak']!);
      return;
    }
    if (compressorPurge == null ||
        compressorPurge < ConfigLimits.compressorPurgeMinS ||
        compressorPurge > ConfigLimits.compressorPurgeMaxS) {
      _snack(t['err_compressor_purge']!);
      return;
    }
    if (pumpAfterHeater == null ||
        pumpAfterHeater < ConfigLimits.pumpAfterHeaterMinS ||
        pumpAfterHeater > ConfigLimits.pumpAfterHeaterMaxS) {
      _snack(t['err_pump_after_heater']!);
      return;
    }
    final tariff = double.tryParse(_tariffCtrl.text.replaceAll(',', '.'));
    if (tariff == null || tariff < 0) {
      _snack(t['err_tariff']!);
      return;
    }

    final updated = notifier.config.copyWith(
      treatmentPriceCents: _priceCents,
      treatmentDurationS: duration,
      servicePin: pin,
      compressorPurgeS: compressorPurge,
      pumpAfterHeaterS: pumpAfterHeater,
      idlePowerTariffPerKwh: tariff,
    );
    notifier.saveConfig(updated);
    _snack(t['saved']!);
  }

  // ---- Мастер-код (R2.0): свой на каждый аппарат, показ один раз ----
  bool _masterAck = false;

  Future<void> _loadMasterState() async {
    final ack = await MasterCodeService.isAcknowledged();
    if (mounted) setState(() => _masterAck = ack);
    // Ввод в эксплуатацию: код ни разу не показан и не подтверждён — показать
    // сразу при входе в меню (PIN к этому моменту уже сменён: вход с
    // начальным PIN ведёт на экран смены). Закрыть без «Я записал» нельзя.
    if (!ack && mounted && !_masterFirstRunShown) {
      _masterFirstRunShown = true;
      await _generateAndShowMasterCode(confirmFirst: false, forced: true);
    }
  }

  bool _masterFirstRunShown = false;

  Future<void> _generateAndShowMasterCode({
    required bool confirmFirst,
    bool forced = false,
  }) async {
    final t = _i18n[context.read<AppNotifier>().lang]!;
    if (confirmFirst) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: const Color(0xFF1A2233),
          title: Text(
            t['mc_change']!,
            style: const TextStyle(color: Colors.white),
          ),
          content: Text(
            t['mc_change_warn']!,
            style: const TextStyle(color: Color(0xFF8899AA)),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text(t['cancel_btn']!),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text(
                t['mc_change']!,
                style: const TextStyle(color: Color(0xFFE53935)),
              ),
            ),
          ],
        ),
      );
      if (ok != true) return;
    }
    final code = await MasterCodeService.generateNew();
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => PopScope(
        canPop: !forced,
        child: AlertDialog(
          backgroundColor: const Color(0xFF1A2233),
          title: Text(
            t['mc_shown_title']!,
            style: const TextStyle(color: Colors.white),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                code,
                style: const TextStyle(
                  color: Color(0xFF00C6B2),
                  fontSize: 40,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 6,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                t['mc_shown_warn']!,
                style: const TextStyle(color: Color(0xFFFFAA00)),
              ),
            ],
          ),
          actions: [
            if (!forced)
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: Text(t['mc_close_unconfirmed']!),
              ),
            TextButton(
              onPressed: () async {
                await MasterCodeService.markAcknowledged();
                if (ctx.mounted) Navigator.of(ctx).pop();
              },
              child: Text(
                t['mc_written']!,
                style: const TextStyle(
                  color: Color(0xFF00C6B2),
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ],
        ),
      ),
    );
    await _loadMasterState();
  }

  Widget _masterCodeSection(Map<String, String> t) {
    return Container(
      margin: const EdgeInsets.only(top: 28),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF141B29),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: _masterAck ? const Color(0xFF00C6B2) : const Color(0xFFFFAA00),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            t['mc_title']!,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            _masterAck ? t['mc_ack']! : t['mc_not_ack']!,
            style: TextStyle(
              color: _masterAck
                  ? const Color(0xFF00C6B2)
                  : const Color(0xFFFFAA00),
              fontSize: 13,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            t['mc_hint']!,
            style: const TextStyle(color: Color(0xFF8899AA), fontSize: 12),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              if (!_masterAck)
                Expanded(
                  child: OutlinedButton(
                    onPressed: () =>
                        _generateAndShowMasterCode(confirmFirst: false),
                    child: Text(t['mc_show']!),
                  ),
                ),
              if (!_masterAck) const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton(
                  onPressed: () =>
                      _generateAndShowMasterCode(confirmFirst: true),
                  child: Text(t['mc_change']!),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _snack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
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
          const SizedBox(height: 16),
          _Field(
            label: t['tariff_label']!,
            controller: _tariffCtrl,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]')),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '${t['idle_cost_label']}: '
            '${_dailyIdleCostEur.toStringAsFixed(2)} €',
            style: const TextStyle(color: Color(0xFF556677), fontSize: 13),
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
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              child: Text(
                t['save']!,
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                ),
              ),
            ),
          ),
          _masterCodeSection(t),
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
    _ctrls = List.generate(kFlavorCount, (i) {
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
    final currentNames = notifier.config.flavorNames;
    final newNames = <String, List<String>>{};
    // Правим только первые kFlavorCount имён, остальные (если раньше
    // было настроено больше — например, после отката с 6/8 ароматов)
    // сохраняем как есть, чтобы не терять их при последующем увеличении
    // kFlavorCount.
    for (int li = 0; li < _langs.length; li++) {
      final lang = _langs[li];
      final existing = List<String>.from(currentNames[lang] ?? const []);
      for (int i = 0; i < kFlavorCount; i++) {
        final value = _ctrls[i][li].text.trim();
        if (i < existing.length) {
          existing[i] = value;
        } else {
          existing.add(value);
        }
      }
      newNames[lang] = existing;
    }
    final updated = notifier.config.copyWith(flavorNames: newNames);
    notifier.saveConfig(updated);
    final t = _i18n[notifier.lang]!;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(t['saved']!)));
  }

  @override
  Widget build(BuildContext context) {
    final t = _i18n[context.watch<AppNotifier>().lang]!;
    // Единый скроллящийся контейнер вместо Expanded(ListView) внутри
    // жёсткой Column: раньше при появлении клавиатуры (тап в поле имени)
    // содержимое вкладки не могло сжаться и вылезало за пределы экрана.
    // SingleChildScrollView гарантирует, что оно просто проскроллится.
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          // Заголовки колонок
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              children: [
                const SizedBox(width: 32),
                ...['RU', 'EN', 'ET'].map(
                  (l) => Expanded(
                    child: Text(
                      l,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Color(0xFF556677),
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          // Список ароматов (kFlavorCount — легко сменить на 6/8)
          ...List.generate(kFlavorCount, (i) {
            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                children: [
                  SizedBox(
                    width: 32,
                    child: Text(
                      '${i + 1}',
                      style: const TextStyle(color: Color(0xFF556677)),
                    ),
                  ),
                  ...List.generate(3, (li) {
                    return Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: TextField(
                          controller: _ctrls[i][li],
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 13,
                          ),
                          decoration: InputDecoration(
                            isDense: true,
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 8,
                            ),
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
            );
          }),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: _save,
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF00C6B2),
                foregroundColor: Colors.black,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              child: Text(
                t['save']!,
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                ),
              ),
            ),
          ),
        ],
      ),
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

// Бэкофф для информационных опросов (задача "убрать бесполезный опрос
// отсутствующих устройств на шине Modbus") — три неудачи подряд увеличивают
// интервал опроса в 10 раз (не больше 30 секунд), любой успешный ответ
// немедленно возвращает обычный интервал. Таймаут самой транзакции (500 мс,
// ModbusRtu) не трогается — здесь меняется только то, как часто уходит
// следующая попытка. Отдельный от сторожа выходов механизм
// (output_watchdog_service.dart) — у сторожа другая задача (быстро заметить
// потерю связи и погасить выходы), замедлять его нельзя.
class _BackoffPoll {
  _BackoffPoll({required this.baseInterval, required this.poll});

  final Duration baseInterval;
  final Future<bool> Function() poll; // true = успешный ответ

  static const _failuresBeforeBackoff = 3;
  static const _maxInterval = Duration(seconds: 30);

  Timer? _timer;
  int _consecutiveFailures = 0;
  Duration _currentInterval = Duration.zero;

  void start() {
    _currentInterval = baseInterval;
    unawaited(_tick());
    _schedule();
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  void _schedule() {
    _timer?.cancel();
    _timer = Timer.periodic(_currentInterval, (_) => _tick());
  }

  Future<void> _tick() async {
    final ok = await poll();
    final previous = _currentInterval;
    if (ok) {
      _consecutiveFailures = 0;
      _currentInterval = baseInterval;
    } else {
      _consecutiveFailures++;
      if (_consecutiveFailures >= _failuresBeforeBackoff) {
        final backedOff = baseInterval * 10;
        _currentInterval = backedOff > _maxInterval ? _maxInterval : backedOff;
      }
    }
    if (_currentInterval != previous) _schedule();
  }
}

class _DiagnosticsTabState extends State<_DiagnosticsTab> {
  final List<bool> _pumpOn = List.filled(8, false);
  bool _compressorOn = false;
  bool _heaterOn = false;
  bool _busy = false;
  // Ручные выходы заблокированы, пока идёт пробный цикл: он владеет
  // выходами, а "Всё выкл." или автовыключение ТЭНа сорвали бы его и вывели
  // исправный аппарат из обслуживания. Учитывается и сам сервис (вкладка
  // могла быть пересоздана, а цикл ещё идёт).
  bool get _outputsLocked => _busy || HeaterTrialService.running;

  Map<String, double> _energy = {
    'voltage': 0.0,
    'current': 0.0,
    'power': 0.0,
    'totalEnergy': 0.0,
  };
  double _monthlyEnergy = 0.0;
  double _previousMonthEnergy = 0.0;
  _BackoffPoll? _energyPoll;

  // Напряжение сети за последний цикл (задача "контроль цикла по
  // электросчётчику", фаза 2, часть 3) — среднее CycleEnergyService за
  // весь цикл, а не мгновенное значение выше (то плавает 227–242 В и само
  // по себе мало что говорит). Берётся из истории событий, а не отдельным
  // полем на счётчике — событие session_complete уже несёт grid_voltage_v.
  double? _lastCycleVoltage;
  bool _lastCycleVoltageLow = false;

  bool _coinDetected = false;
  _BackoffPoll? _coinPoll;

  // Отладочная имитация отказа монетоприёмника (задача "контроль цикла по
  // электросчётчику") — НЕ часть AppConfig, живёт только в памяти нативного
  // слоя (см. ModbusService.setCoinAcceptorSimulatedDown). Воспроизводит
  // ветку отказа сколько угодно раз одинаково, без риска для железа и без
  // зависимости от способа, которым реально отваливается связь. Специально
  // НЕ сбрасывается при уходе со вкладки (в отличие от ручного управления
  // выходами ниже) — тест нужно проверить на реальном экране оплаты,
  // который лежит за пределами этого таба; сброс по dispose() гасил бы
  // имитацию раньше, чем payment.dart успевал её увидеть. Гасится вручную
  // тумблером, перезапуском приложения или сама через 30 минут на
  // нативной стороне (ModbusChannel.COIN_SIMULATED_DOWN_AUTO_OFF_MS,
  // фаза 2, страховка) — _simulateDownPoll ниже подхватывает этот
  // автосброс, пока вкладка открыта, чтобы тумблер не показывал
  // "включено" уже после того, как аппарат сам всё вернул как было.
  bool _simulateCoinDown = false;
  Timer? _simulateDownPoll;

  // Отладочная "заморозка" показания температуры (задача "детектор отказа
  // датчика температуры", часть 2, п.11) — те же правила, что у тумблера
  // выше: живёт в нативном слое до ручного выключения, автоснятие через
  // 30 минут (ModbusChannel.TEMPERATURE_FROZEN_AUTO_OFF_MS), состояние
  // видно в облаке и в регулярной отправке состояния. Проверка идёт с
  // физически включённым ТЭНом — техник стоит рядом.
  bool _freezeTemperature = false;
  double? _frozenTemperatureValue;

  // Пробный цикл (вывод из обслуживания, требования 15-16).
  bool _trialRunning = false;
  String? _trialMessage;
  bool _trialMessageOk = false;

  double? _temperature;
  _BackoffPoll? _tempPoll;

  late bool _watchdogEnabled;

  // Флаги "установлено" (задача "убрать бесполезный опрос отсутствующих
  // устройств") — снятый флаг вообще не заводит опрос соответствующего
  // устройства, см. initState.
  late bool _thermoInstalled;
  late bool _energyMeterInstalled;
  late bool _coinAcceptorInstalled;

  // --- Автовыключение силовых выходов (задача "тест каналов
  // ввода-вывода") — любой выход, включённый с этого экрана, гаснет сам
  // через 10 секунд. Это диагностический экран прямого управления
  // насосами/компрессором/ТЭНом мимо обычной логики аппарата — таймер
  // здесь уместен и нужен, в основном рабочем цикле его нет и не должно
  // быть (отдельное требование задачи).
  static const _autoOffSeconds = 10;
  final Map<int, Timer> _pumpOffTimers = {};
  final Map<int, int> _pumpSecondsLeft = {};
  Timer? _compressorOffTimer;
  int? _compressorSecondsLeft;
  Timer? _heaterOffTimer;
  int? _heaterSecondsLeft;

  @override
  void initState() {
    super.initState();
    final cfg = context.read<AppNotifier>().config;
    _watchdogEnabled = cfg.outputWatchdogEnabled;
    _thermoInstalled = cfg.thermoInstalled;
    _energyMeterInstalled = cfg.energyMeterInstalled;
    _coinAcceptorInstalled = cfg.coinAcceptorInstalled;

    // Флаг имитации отказа монетоприёмника живёт в нативном слое дольше,
    // чем эта вкладка (см. _simulateCoinDown) — при пересоздании вкладки
    // тумблер обязан показать реальное состояние, а не всегда "выключено".
    ModbusService.getCoinAcceptorSimulatedDown().then((value) {
      if (mounted) setState(() => _simulateCoinDown = value);
    });
    ModbusService.getTemperatureFrozen().then((r) {
      if (mounted) {
        setState(() {
          _freezeTemperature = r.frozen;
          _frozenTemperatureValue = r.value;
        });
      }
    });
    // Раз в минуту, пока вкладка открыта — ловит автосброс через 30 минут,
    // не дожидаясь пересоздания вкладки (см. коммент у _simulateCoinDown).
    _simulateDownPoll = Timer.periodic(const Duration(minutes: 1), (_) {
      ModbusService.getCoinAcceptorSimulatedDown().then((value) {
        if (mounted && value != _simulateCoinDown) {
          setState(() => _simulateCoinDown = value);
        }
      });
      ModbusService.getTemperatureFrozen().then((r) {
        if (mounted && r.frozen != _freezeTemperature) {
          setState(() {
            _freezeTemperature = r.frozen;
            _frozenTemperatureValue = r.value;
          });
        }
      });
    });

    unawaited(_loadLastCycleVoltage());

    // Снятый флаг "установлено" — опрос этого устройства не заводится
    // вообще, ни одна транзакция на шину не уходит (задача "убрать
    // бесполезный опрос отсутствующих устройств").
    if (_energyMeterInstalled) {
      _energyPoll = _BackoffPoll(
        baseInterval: const Duration(seconds: 3),
        poll: _readEnergy,
      )..start();
    }
    if (_coinAcceptorInstalled) {
      _coinPoll = _BackoffPoll(
        baseInterval: const Duration(milliseconds: 500),
        poll: _readCoin,
      )..start();
    }
    if (_thermoInstalled) {
      _tempPoll = _BackoffPoll(
        baseInterval: const Duration(seconds: 2),
        poll: _readTemperature,
      )..start();
    }
  }

  @override
  void dispose() {
    _energyPoll?.stop();
    _coinPoll?.stop();
    _tempPoll?.stop();
    for (final timer in _pumpOffTimers.values) {
      timer.cancel();
    }
    _compressorOffTimer?.cancel();
    _heaterOffTimer?.cancel();
    _simulateDownPoll?.cancel();
    // Выходы сейчас погасит safeAllOff() ниже — пробный цикл вышел бы
    // "провалом" на исправном аппарате, поэтому он помечается прерванным.
    HeaterTrialService.cancel();
    // Уход с экрана — гасит все выходы принудительно (задача "тест
    // каналов ввода-вывода", требование безопасности). dispose()
    // синхронный, выключение не обязано его блокировать.
    unawaited(ModbusService.safeAllOff());
    super.dispose();
  }

  void _snack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  Map<String, String> get _t => _i18n[context.read<AppNotifier>().lang]!;

  Future<bool> _confirmLoad(String loadName) async {
    final t = _t;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF141B29),
        title: Text(
          t['diag_confirm_title']!,
          style: const TextStyle(color: Colors.white),
        ),
        content: Text(
          '${t['diag_confirm_body']} "$loadName"?',
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(
              t['scanner_write_confirm_cancel']!,
              style: const TextStyle(color: Color(0xFF8899AA)),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(
              t['all_on']!,
              style: const TextStyle(
                color: Color(0xFFE53935),
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );
    return confirmed == true;
  }

  void _armPumpAutoOff(int i) {
    _pumpOffTimers[i]?.cancel();
    setState(() => _pumpSecondsLeft[i] = _autoOffSeconds);
    _pumpOffTimers[i] = Timer.periodic(const Duration(seconds: 1), (timer) {
      final left = (_pumpSecondsLeft[i] ?? 1) - 1;
      if (left <= 0) {
        timer.cancel();
        _pumpOffTimers.remove(i);
        if (mounted) setState(() => _pumpSecondsLeft.remove(i));
        unawaited(_setPump(i, false));
      } else if (mounted) {
        setState(() => _pumpSecondsLeft[i] = left);
      }
    });
  }

  void _disarmPumpAutoOff(int i) {
    _pumpOffTimers.remove(i)?.cancel();
    if (mounted) setState(() => _pumpSecondsLeft.remove(i));
  }

  void _armCompressorAutoOff() {
    _compressorOffTimer?.cancel();
    setState(() => _compressorSecondsLeft = _autoOffSeconds);
    _compressorOffTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      final left = (_compressorSecondsLeft ?? 1) - 1;
      if (left <= 0) {
        timer.cancel();
        _compressorOffTimer = null;
        if (mounted) setState(() => _compressorSecondsLeft = null);
        unawaited(_setCompressor(false));
      } else if (mounted) {
        setState(() => _compressorSecondsLeft = left);
      }
    });
  }

  void _disarmCompressorAutoOff() {
    _compressorOffTimer?.cancel();
    _compressorOffTimer = null;
    if (mounted) setState(() => _compressorSecondsLeft = null);
  }

  void _armHeaterAutoOff() {
    _heaterOffTimer?.cancel();
    setState(() => _heaterSecondsLeft = _autoOffSeconds);
    _heaterOffTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      final left = (_heaterSecondsLeft ?? 1) - 1;
      if (left <= 0) {
        timer.cancel();
        _heaterOffTimer = null;
        if (mounted) setState(() => _heaterSecondsLeft = null);
        unawaited(_setHeater(false));
      } else if (mounted) {
        setState(() => _heaterSecondsLeft = left);
      }
    });
  }

  void _disarmHeaterAutoOff() {
    _heaterOffTimer?.cancel();
    _heaterOffTimer = null;
    if (mounted) setState(() => _heaterSecondsLeft = null);
  }

  // "Проверить состояние после включения питания" — модуль не должен сам
  // поднимать выходы при подаче питания (см. также сторож выходов,
  // отдельная задача). Здесь — разовая ручная проверка прямо с этого
  // экрана, без включённого сторожа.
  Future<void> _checkColdStart() async {
    final t = _t;
    final coils = await ModbusService.readCoils();
    if (!mounted) return;
    if (coils == null) {
      _snack(t['diag_cold_start_error']!);
    } else if (coils.every((v) => !v)) {
      _snack(t['diag_cold_start_ok']!);
    } else {
      final onChannels = [
        for (var i = 0; i < coils.length; i++)
          if (coils[i]) i,
      ];
      _snack('${t['diag_cold_start_fail']}: ${onChannels.join(', ')}');
    }
  }

  Future<bool> _readCoin() async {
    final detected = await ModbusService.readCoin();
    if (mounted) setState(() => _coinDetected = detected ?? false);
    return detected != null;
  }

  Future<bool> _readTemperature() async {
    final temp = await ModbusService.readTemperature(channel: 0);
    if (mounted) setState(() => _temperature = temp);
    return temp != null;
  }

  Future<bool> _readEnergy() async {
    final energy = await ModbusService.readEnergy();
    final monthly = await ModbusService.getMonthlyEnergy();
    final previousMonth = await ModbusService.getPreviousMonthEnergy();
    if (mounted) {
      setState(() {
        // Показания на вкладке диагностики — если чтение не удалось,
        // просто оставляем прежние значения на экране (null здесь означал
        // бы ошибку, а не честный ноль — см. ModbusService.readEnergy).
        if (energy != null) _energy = energy;
        _monthlyEnergy = monthly;
        _previousMonthEnergy = previousMonth;
      });
    }
    return energy != null;
  }

  // Задача "контроль цикла по электросчётчику", фаза 2, часть 3 —
  // напряжение сети последнего реального цикла, из уже отправленной
  // истории событий (не отдельный опрос шины). Локальная история хранит
  // сессии и без облака (LocalLogTransport), так что это работает и без
  // подключённой панели.
  Future<void> _loadLastCycleVoltage() async {
    final history = await CloudService.history();
    for (final event in history.reversed) {
      if (event.type != CloudEventType.sessionComplete) continue;
      final voltage = event.data['grid_voltage_v'];
      if (voltage is num) {
        if (mounted) {
          setState(() {
            _lastCycleVoltage = voltage.toDouble();
            _lastCycleVoltageLow = event.data['voltage_low'] == true;
          });
        }
        return;
      }
    }
  }

  Future<void> _setPump(int i, bool value) async {
    setState(() => _pumpOn[i] = value);
    final ok = await ModbusService.setPump(i, value);
    if (!ok && mounted) {
      setState(() => _pumpOn[i] = !value);
      return;
    }
    if (value) {
      _armPumpAutoOff(i);
    } else {
      _disarmPumpAutoOff(i);
    }
  }

  // Компрессор и ТЭН — с подтверждением перед включением (задача "тест
  // каналов ввода-вывода", силовая часть) — насосы не требуют, там нет
  // такого риска.
  Future<void> _setCompressor(bool value) async {
    if (value && !await _confirmLoad(_t['compressor']!)) return;
    setState(() => _compressorOn = value);
    final ok = await ModbusService.setCompressor(value);
    if (!ok && mounted) {
      setState(() => _compressorOn = !value);
      return;
    }
    if (value) {
      _armCompressorAutoOff();
    } else {
      _disarmCompressorAutoOff();
    }
  }

  Future<void> _setHeater(bool value) async {
    if (value && !await _confirmLoad(_t['heater']!)) return;
    setState(() => _heaterOn = value);
    final ok = await ModbusService.setHeater(value);
    if (!ok && mounted) {
      setState(() => _heaterOn = !value);
      return;
    }
    if (value) {
      _armHeaterAutoOff();
    } else {
      _disarmHeaterAutoOff();
    }
  }

  Future<void> _allOn() async {
    final t = _t;
    if (!await _confirmLoad('${t['compressor']} + ${t['heater']}')) return;
    setState(() => _busy = true);
    for (var i = 0; i < 8; i++) {
      await ModbusService.setPump(i, true);
      _armPumpAutoOff(i);
    }
    await ModbusService.setCompressor(true);
    _armCompressorAutoOff();
    await ModbusService.setHeater(true);
    _armHeaterAutoOff();
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
    for (var i = 0; i < 8; i++) {
      _disarmPumpAutoOff(i);
    }
    _disarmCompressorAutoOff();
    _disarmHeaterAutoOff();
    await ModbusService.safeAllOff();
    if (!mounted) return;
    setState(() {
      _pumpOn.fillRange(0, 8, false);
      _compressorOn = false;
      _heaterOn = false;
      _busy = false;
    });
  }

  // Задача "починить обмен по шине", 4 — по умолчанию выключен, сохраняется
  // сразу при переключении (тот же приём, что и киоск-режим), без отдельной
  // кнопки "Сохранить".
  Future<void> _toggleWatchdog(bool value) async {
    setState(() => _watchdogEnabled = value);
    final notifier = context.read<AppNotifier>();
    await notifier.saveConfig(
      notifier.config.copyWith(outputWatchdogEnabled: value),
    );
  }

  // "Установлено" — техник переключает сразу после физического
  // подключения/отключения устройства (задача "Chint DDSU666: найти
  // счётчик"). Переключение сразу запускает/останавливает информационный
  // опрос — не только сохраняет флаг в конфиг, иначе пришлось бы
  // объяснять "сохранилось, подействует после ухода со вкладки".
  Future<void> _toggleEnergyMeterInstalled(bool value) async {
    setState(() {
      _energyMeterInstalled = value;
      if (value) {
        _energyPoll = _BackoffPoll(
          baseInterval: const Duration(seconds: 3),
          poll: _readEnergy,
        )..start();
      } else {
        _energyPoll?.stop();
        _energyPoll = null;
      }
    });
    final notifier = context.read<AppNotifier>();
    await notifier.saveConfig(
      notifier.config.copyWith(energyMeterInstalled: value),
    );
  }

  Future<void> _toggleThermoInstalled(bool value) async {
    setState(() {
      _thermoInstalled = value;
      if (value) {
        _tempPoll = _BackoffPoll(
          baseInterval: const Duration(seconds: 2),
          poll: _readTemperature,
        )..start();
      } else {
        _tempPoll?.stop();
        _tempPoll = null;
      }
    });
    final notifier = context.read<AppNotifier>();
    await notifier.saveConfig(notifier.config.copyWith(thermoInstalled: value));
  }

  Future<void> _toggleCoinAcceptorInstalled(bool value) async {
    setState(() {
      _coinAcceptorInstalled = value;
      if (value) {
        _coinPoll = _BackoffPoll(
          baseInterval: const Duration(milliseconds: 500),
          poll: _readCoin,
        )..start();
      } else {
        _coinPoll?.stop();
        _coinPoll = null;
      }
    });
    final notifier = context.read<AppNotifier>();
    await notifier.saveConfig(
      notifier.config.copyWith(coinAcceptorInstalled: value),
    );
  }

  // Отладочный переключатель "имитировать отказ монетоприёмника" — НЕ
  // часть AppConfig, живёт в памяти нативного слоя (см. коммент у поля
  // _simulateCoinDown выше). Ничего не читает и не пишет на шину — просто
  // просит нативную сторону подделать результат getCoinAcceptorStatus();
  // та же сторона сама снимает имитацию через 30 минут, если забыли (см.
  // ModbusChannel.COIN_SIMULATED_DOWN_AUTO_OFF_MS).
  Future<void> _toggleSimulateCoinDown(bool value) async {
    setState(() => _simulateCoinDown = value);
    await ModbusService.setCoinAcceptorSimulatedDown(value);
    // Аппарат, принимающий деньги, не должен уметь спрятать, что он в
    // отладочном режиме — видно в веб-панели, даже если никто не стоит
    // рядом с планшетом (задача "контроль цикла по электросчётчику",
    // фаза 2, страховка).
    if (value) {
      unawaited(
        CloudService.report(
          CloudEventType.debugModeChanged,
          data: {
            'code': 'simulate_coin_acceptor_down',
            'enabled': true,
            'auto_off_minutes': 30,
          },
        ),
      );
    } else {
      unawaited(
        CloudService.report(
          CloudEventType.debugModeChanged,
          data: {'code': 'simulate_coin_acceptor_down', 'enabled': false},
        ),
      );
    }
  }

  // Заморозка показания термопары (см. _freezeTemperature). Включение
  // уходит в облако событием debug_mode_changed, как и у тумблера
  // монетоприёмника.
  Future<void> _toggleFreezeTemperature(bool value) async {
    final frozenAt = await ModbusService.setTemperatureFrozen(value);
    if (!mounted) return;
    setState(() {
      // Если заморозить было нечем (нет ни одного чтения, шина молчит) —
      // тумблер честно остаётся выключенным.
      _freezeTemperature = value && frozenAt != null;
      _frozenTemperatureValue = _freezeTemperature ? frozenAt : null;
    });
    if (value && frozenAt == null) {
      _snack(_t['diag_freeze_temp_failed']!);
      return;
    }
    unawaited(
      CloudService.report(
        CloudEventType.debugModeChanged,
        data: {
          'code': 'freeze_temperature',
          'enabled': value,
          if (value) 'auto_off_minutes': 30,
          'frozen_at_c': ?frozenAt,
        },
      ),
    );
  }

  // Пробный цикл без оплаты (вывод из обслуживания, требования 15-16).
  Future<void> _runTrial() async {
    final notifier = context.read<AppNotifier>();
    final t = _t;
    // Ручные выходы на время пробного цикла блокируются (_busy) и их
    // автовыключатели (10 с) снимаются: иначе "Всё выкл." или таймер
    // выключения ТЭНа срывали бы цикл, и исправный аппарат выводился бы из
    // обслуживания. Что было включено вручную — выключается: цикл сам
    // владеет выходами.
    for (var i = 0; i < 8; i++) {
      _disarmPumpAutoOff(i);
    }
    _disarmCompressorAutoOff();
    _disarmHeaterAutoOff();
    setState(() {
      _trialRunning = true;
      _busy = true;
      _trialMessage = null;
      _pumpOn.fillRange(0, 8, false);
      _compressorOn = false;
      _heaterOn = false;
    });
    final result = await HeaterTrialService.runAndRecord(notifier);
    if (!mounted) return;
    String message;
    if (result.passed) {
      message = notifier.isOutOfService
          ? t['oos_trial_pass']!
          : t['oos_trial_pass_healthy']!;
    } else if (result.skipped) {
      message = switch (result.code) {
        'too_hot' =>
          '${t['oos_trial_too_hot']} (${result.details['temp_c']}°C)',
        'cancelled' => t['oos_trial_cancelled']!,
        'no_thermocouple' => t['oos_trial_no_thermo']!,
        _ => t['oos_trial_busy']!,
      };
    } else {
      final sub = result.details['subtype'];
      message =
          '${t['oos_trial_fail']}: ${result.code}${sub != null ? ' / $sub' : ''}';
    }
    setState(() {
      _trialRunning = false;
      _busy = false;
      _trialMessage = message;
      _trialMessageOk = result.passed;
    });
  }

  // Снять блокировку — только отсюда, на месте, с подтверждением и только
  // после свежего успешного пробного цикла (требования 12, 13, 16).
  Future<void> _clearOutOfService() async {
    final t = _t;
    final notifier = context.read<AppNotifier>();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF141B29),
        title: Text(
          t['oos_clear_confirm_title']!,
          style: const TextStyle(color: Colors.white),
        ),
        content: Text(
          t['oos_clear_confirm_body']!,
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(
              t['scanner_write_confirm_cancel']!,
              style: const TextStyle(color: Color(0xFF8899AA)),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(
              t['oos_clear_btn']!,
              style: const TextStyle(
                color: Color(0xFFE53935),
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final ok = await OutOfServiceService.clearByTechnician(notifier);
    if (!mounted) return;
    _snack(ok ? t['oos_cleared']! : t['oos_clear_failed']!);
  }

  // Карточка состояния "выведен из обслуживания" + пробный цикл + снятие.
  Widget _outOfServiceCard(AppNotifier notifier, Map<String, String> t) {
    final oos = notifier.outOfService;
    final blocked = oos != null;
    final canClear = blocked && OutOfServiceService.trialPassedRecently;
    final cfgBlocked = !blocked && notifier.isConfigBlocked;
    final accent = blocked
        ? const Color(0xFFE53935)
        : cfgBlocked
        ? const Color(0xFFFFAA00)
        : const Color(0xFF00C6B2);
    String deviceName(String code) => switch (code) {
      'thermocouple' => t['diag_device_thermo']!,
      'energy_meter' => t['diag_device_energy']!,
      _ => code,
    };

    String reasonText(String code) => switch (code) {
      OutOfServiceCode.heaterNoPower => t['oos_code_heater_no_power']!,
      OutOfServiceCode.tempSensorFault => t['oos_code_temp_sensor_fault']!,
      OutOfServiceCode.heatTimeout => t['oos_code_heat_timeout']!,
      OutOfServiceCode.heaterOffUnconfirmed =>
        t['oos_code_heater_off_unconfirmed']!,
      OutOfServiceCode.overheat => t['oos_code_overheat']!,
      OutOfServiceCode.outputStuckOn => t['oos_code_output_stuck_on']!,
      OutOfServiceCode.stateUnreadable => t['oos_code_state_unreadable']!,
      _ => code,
    };

    String? detailLine(OutOfServiceState s) {
      final d = s.details;
      final parts = <String>[
        if (d['subtype'] != null) '${d['subtype']}',
        if (d['confirmed_by'] != null) '${d['confirmed_by']}',
        if (d['power_w'] is num)
          '${(d['power_w'] as num).toStringAsFixed(0)} ${t['unit_w']}',
        if (d['voltage_v'] is num)
          '${(d['voltage_v'] as num).toStringAsFixed(0)} ${t['unit_v']}',
        if (d['temp_c'] is num)
          '${(d['temp_c'] as num).toStringAsFixed(1)} °C'
        else if (d['last_temp_c'] is num)
          '${(d['last_temp_c'] as num).toStringAsFixed(1)} °C',
      ];
      return parts.isEmpty ? null : parts.join(' · ');
    }

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF141B29),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: accent.withValues(alpha: 0.6)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            blocked
                ? t['oos_status_blocked']!
                : cfgBlocked
                ? t['oos_status_cfg_blocked']!
                : t['oos_status_ok']!,
            style: TextStyle(
              color: accent,
              fontWeight: FontWeight.bold,
              fontSize: 14,
            ),
          ),
          if (cfgBlocked) ...[
            const SizedBox(height: 6),
            Text(
              '${t['oos_cfg_missing']}: ${notifier.missingRequiredDevices.map(deviceName).join(', ')}',
              style: const TextStyle(color: Color(0xFFFFAA00), fontSize: 12),
            ),
          ],
          if (oos != null) ...[
            const SizedBox(height: 8),
            Text(
              '${t['oos_reason']}: ${reasonText(oos.code)}',
              style: const TextStyle(color: Colors.white, fontSize: 13),
            ),
            const SizedBox(height: 4),
            Text(
              '${t['oos_since']}: ${oos.since.toLocal().toString().split('.').first}',
              style: const TextStyle(color: Color(0xFF8899AA), fontSize: 12),
            ),
            if (detailLine(oos) != null) ...[
              const SizedBox(height: 4),
              Text(
                detailLine(oos)!,
                style: const TextStyle(color: Color(0xFF8899AA), fontSize: 12),
              ),
            ],
          ],
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton(
              onPressed: _trialRunning ? null : _runTrial,
              style: OutlinedButton.styleFrom(
                foregroundColor: const Color(0xFF00C6B2),
                side: const BorderSide(color: Color(0xFF00C6B2)),
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              child: Text(
                _trialRunning ? t['oos_trial_running']! : t['oos_trial_btn']!,
              ),
            ),
          ),
          if (_trialRunning || HeaterTrialService.running) ...[
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton(
                onPressed: HeaterTrialService.cancel,
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFFE53935),
                  side: const BorderSide(color: Color(0xFFE53935)),
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                child: Text(t['oos_trial_abort']!),
              ),
            ),
          ],
          const SizedBox(height: 6),
          Text(
            t['oos_trial_hint']!,
            style: const TextStyle(color: Color(0xFF556677), fontSize: 12),
          ),
          if (_trialMessage != null) ...[
            const SizedBox(height: 8),
            Text(
              _trialMessage!,
              style: TextStyle(
                color: _trialMessageOk
                    ? const Color(0xFF00C6B2)
                    : const Color(0xFFFFAA00),
                fontWeight: FontWeight.bold,
                fontSize: 13,
              ),
            ),
          ],
          if (blocked) ...[
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: canClear && !_trialRunning
                    ? _clearOutOfService
                    : null,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFE53935),
                  foregroundColor: Colors.white,
                  disabledBackgroundColor: const Color(0xFF2A3342),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                child: Text(t['oos_clear_btn']!),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              t['oos_clear_hint']!,
              style: const TextStyle(color: Color(0xFF556677), fontSize: 12),
            ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final notifier = context.watch<AppNotifier>();
    final lang = notifier.lang;
    final t = _i18n[lang]!;
    final levels = notifier.levels;
    final flavors = notifier.config.flavorNames[lang] ?? [];
    final busHealthy = notifier.busHealthy;
    final busBusyPort = notifier.busBusyPort;
    final busBusyPid = notifier.busBusyPid;

    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        // Признак работоспособности шины (задача "починить обмен по
        // шине", 5.3) — техник должен видеть текущее состояние, не
        // догадываясь по симптомам вроде "клиенты жалуются, что не
        // принимает деньги".
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: const Color(0xFF141B29),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 10,
                    height: 10,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: busHealthy
                          ? const Color(0xFF00C6B2)
                          : const Color(0xFFE53935),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    busHealthy ? t['bus_healthy']! : t['bus_unhealthy']!,
                    style: TextStyle(
                      color: busHealthy
                          ? const Color(0xFF00C6B2)
                          : const Color(0xFFE53935),
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                    ),
                  ),
                ],
              ),
              // Деталь "почему" (задача "эксклюзивное открытие
              // последовательного порта") — технику, не клиенту: клиентский
              // экран ошибки остаётся на общем "аппарат временно не
              // работает" без технических подробностей.
              if (!busHealthy && busBusyPort != null) ...[
                const SizedBox(height: 6),
                Text(
                  busBusyPid != null
                      ? '${t['diag_port_busy']} $busBusyPort (PID $busBusyPid)'
                      : '${t['diag_port_busy']} $busBusyPort',
                  style: const TextStyle(
                    color: Color(0xFFE53935),
                    fontSize: 12,
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 16),

        _outOfServiceCard(notifier, t),
        const SizedBox(height: 16),

        // Сторож выходов (задача "починить обмен по шине", 4) — по
        // умолчанию выключен, диагностический режим.
        _ToggleRow(
          label: t['watchdog_enabled']!,
          value: _watchdogEnabled,
          onChanged: _toggleWatchdog,
        ),
        const SizedBox(height: 6),
        Text(
          t['watchdog_hint']!,
          style: const TextStyle(color: Color(0xFF556677), fontSize: 12),
        ),
        const SizedBox(height: 20),
        Container(height: 1, color: const Color(0xFF1A2233)),
        const SizedBox(height: 20),

        // "Установлено" — переключается техником сразу по факту физического
        // монтажа/демонтажа устройства (задача "Chint DDSU666: найти
        // счётчик"). Модуль ввода-вывода сюда не входит — он всегда
        // реально на шине (BusDevice.dio, bus_map.dart), переключатель
        // для него был бы декоративным.
        Text(
          t['diag_devices_section']!,
          style: const TextStyle(
            color: Color(0xFF556677),
            fontWeight: FontWeight.bold,
            fontSize: 13,
          ),
        ),
        const SizedBox(height: 8),
        _ToggleRow(
          label: t['diag_device_thermo']!,
          value: _thermoInstalled,
          onChanged: _toggleThermoInstalled,
        ),
        _ToggleRow(
          label: t['diag_device_energy']!,
          value: _energyMeterInstalled,
          onChanged: _toggleEnergyMeterInstalled,
        ),
        _ToggleRow(
          label: t['diag_device_coin']!,
          value: _coinAcceptorInstalled,
          onChanged: _toggleCoinAcceptorInstalled,
        ),
        const SizedBox(height: 20),
        Container(height: 1, color: const Color(0xFF1A2233)),
        const SizedBox(height: 20),

        Text(
          t['diag_levels']!,
          style: const TextStyle(
            color: Color(0xFF556677),
            fontWeight: FontWeight.bold,
            fontSize: 13,
          ),
        ),
        const SizedBox(height: 12),
        // Ряды по 4 карточки — под ландшафтную ширину. kFlavorCount=4
        // укладывается в один ряд; при 6/8 появятся дополнительные ряды
        // автоматически.
        ...List.generate((kFlavorCount / 4).ceil(), (row) {
          final start = row * 4;
          final count = (kFlavorCount - start).clamp(0, 4);
          return Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Row(
              children: [
                for (var col = 0; col < count; col++) ...[
                  if (col > 0) const SizedBox(width: 10),
                  Expanded(
                    child: _LevelBadge(
                      index: start + col,
                      levels: levels,
                      flavors: flavors,
                      t: t,
                    ),
                  ),
                ],
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
              Text(
                '${t['coin_label']}:',
                style: const TextStyle(color: Colors.white, fontSize: 14),
              ),
              const SizedBox(width: 8),
              Text(
                !_coinAcceptorInstalled
                    ? '${t['temp_unavailable']} · ${t['not_installed']}'
                    : _coinDetected
                    ? t['coin_yes']!
                    : t['coin_no']!,
                style: TextStyle(
                  color: !_coinAcceptorInstalled
                      ? const Color(0xFF556677)
                      : _coinDetected
                      ? const Color(0xFF00C6B2)
                      : const Color(0xFF556677),
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        _ToggleRow(
          label: t['diag_simulate_coin_down']!,
          value: _simulateCoinDown,
          onChanged: _toggleSimulateCoinDown,
        ),
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Text(
            t['diag_simulate_coin_down_hint']!,
            style: const TextStyle(color: Color(0xFF556677), fontSize: 12),
          ),
        ),
        _ToggleRow(
          label: t['diag_freeze_temp']!,
          value: _freezeTemperature,
          onChanged: _toggleFreezeTemperature,
        ),
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Text(
            _freezeTemperature && _frozenTemperatureValue != null
                ? '${t['diag_freeze_temp_hint']} '
                      '(${_frozenTemperatureValue!.toStringAsFixed(1)} °C)'
                : t['diag_freeze_temp_hint']!,
            style: const TextStyle(color: Color(0xFF556677), fontSize: 12),
          ),
        ),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: const Color(0xFF141B29),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              Text(
                '${t['temp_label']}:',
                style: const TextStyle(color: Colors.white, fontSize: 14),
              ),
              const SizedBox(width: 8),
              Text(
                !_thermoInstalled
                    ? '${t['temp_unavailable']} · ${t['not_installed']}'
                    : _temperature != null
                    ? '${_temperature!.toStringAsFixed(1)} °C'
                    : t['temp_unavailable']!,
                style: TextStyle(
                  color: !_thermoInstalled
                      ? const Color(0xFF556677)
                      : _temperature != null
                      ? const Color(0xFF00C6B2)
                      : const Color(0xFFE53935),
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

        Text(
          t['diag_manual']!,
          style: const TextStyle(
            color: Color(0xFF556677),
            fontWeight: FontWeight.bold,
            fontSize: 13,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          t['diag_manual_warning']!,
          style: const TextStyle(color: Color(0xFF8899AA), fontSize: 12),
        ),
        const SizedBox(height: 12),

        ...(() {
          final toggles = <Widget>[
            // Все 8 физических каналов насоса остаются доступны для
            // ручного теста (полная ёмкость DIO-модуля), но имя аромата
            // подписывается только для реально активных (kFlavorCount).
            ...List.generate(8, (i) {
              final label = i < kFlavorCount
                  ? '${t['pump']} ${i + 1} '
                        '(${flavors.length > i ? flavors[i] : '${t['flavor_fallback']} ${i + 1}'})'
                  : '${t['pump']} ${i + 1}';
              final secondsLeft = _pumpSecondsLeft[i];
              return _ToggleRow(
                label: secondsLeft != null
                    ? '$label — $secondsLeft${t['diag_seconds_suffix']}'
                    : label,
                value: _pumpOn[i],
                onChanged: _outputsLocked ? null : (v) => _setPump(i, v),
              );
            }),
            _ToggleRow(
              label: _compressorSecondsLeft != null
                  ? '${t['compressor']} — $_compressorSecondsLeft${t['diag_seconds_suffix']}'
                  : t['compressor']!,
              value: _compressorOn,
              onChanged: _outputsLocked ? null : _setCompressor,
            ),
            _ToggleRow(
              label: _heaterSecondsLeft != null
                  ? '${t['heater']} — $_heaterSecondsLeft${t['diag_seconds_suffix']}'
                  : t['heater']!,
              value: _heaterOn,
              onChanged: _outputsLocked ? null : _setHeater,
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
                onPressed: _outputsLocked ? null : _allOn,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF00C6B2),
                  foregroundColor: Colors.black,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                child: Text(
                  t['all_on']!,
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: ElevatedButton(
                onPressed: _outputsLocked ? null : _allOff,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFE53935),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                child: Text(
                  t['all_off']!,
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
            ),
          ],
        ),

        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton(
            onPressed: _outputsLocked ? null : _checkColdStart,
            style: OutlinedButton.styleFrom(
              foregroundColor: const Color(0xFF00C6B2),
              side: const BorderSide(color: Color(0xFF00C6B2)),
              padding: const EdgeInsets.symmetric(vertical: 12),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            child: Text(t['diag_cold_start_btn']!),
          ),
        ),

        const SizedBox(height: 24),
        const Divider(color: Color(0xFF1A2233)),
        const SizedBox(height: 12),

        Row(
          children: [
            Text(
              t['diag_energy']!,
              style: const TextStyle(
                color: Color(0xFF556677),
                fontWeight: FontWeight.bold,
                fontSize: 13,
              ),
            ),
            const Spacer(),
            TextButton(
              onPressed: _readEnergy,
              child: Text(
                t['refresh']!,
                style: const TextStyle(color: Color(0xFF00C6B2)),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (!_energyMeterInstalled)
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: const Color(0xFF141B29),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              '${t['temp_unavailable']} · ${t['not_installed']}',
              style: const TextStyle(
                color: Color(0xFF556677),
                fontWeight: FontWeight.bold,
                fontSize: 14,
              ),
            ),
          )
        else ...[
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
                if (_lastCycleVoltage != null) ...[
                  const SizedBox(height: 6),
                  Text(
                    '${t['last_cycle_voltage']}: '
                    '${_lastCycleVoltage!.toStringAsFixed(0)} ${t['unit_v']}'
                    '${_lastCycleVoltageLow ? ' ⚠' : ''}',
                    style: TextStyle(
                      color: _lastCycleVoltageLow
                          ? const Color(0xFFFFAA00)
                          : Colors.white,
                      fontSize: 14,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
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
        Text(
          label,
          style: const TextStyle(color: Color(0xFF8899AA), fontSize: 12),
        ),
        const SizedBox(height: 4),
        Text(
          '${value.toStringAsFixed(1)} $unit',
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.bold,
            fontSize: 16,
          ),
        ),
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

  // --- Платёжный терминал (задача "терминал", задача 7) ---
  late TextEditingController _terminalChannelCtrl;
  late TextEditingController _terminalGuardCtrl;
  late String _terminalMode;
  late bool _terminalEnabled;
  bool? _terminalState;
  List<String> _terminalJournal = [];
  Timer? _terminalObserveTimer;
  bool _observing = false;
  // Защита от повторного входа — один тик делает 2 последовательных
  // запроса к шине (pollTerminal + getTerminalJournal). Без флага
  // Timer.periodic всё равно стрелял бы каждые 30 мс, даже если
  // предыдущий тик ещё не завершился — тики бы копились и накладывались,
  // а порядок печати в журнале переставал совпадать с реальным порядком
  // событий. Тот же приём, что и в LevelService._tick.
  bool _pollingTerminal = false;
  // Последнее известное состояние ВСЕХ 16 входов — только для диагностики
  // "правильный ли канал терминала выбран" (см. _pollTerminalOnce).
  List<bool>? _lastAllChannels;

  @override
  void initState() {
    super.initState();
    final cfg = context.read<AppNotifier>().config;
    _terminalChannelCtrl = TextEditingController(
      text: cfg.paymentTerminalChannel.toString(),
    );
    _terminalGuardCtrl = TextEditingController(
      text: cfg.paymentTerminalGuardMs.toString(),
    );
    _terminalMode = cfg.paymentTerminalMode;
    _terminalEnabled = cfg.paymentTerminalEnabled;
  }

  @override
  void dispose() {
    _terminalObserveTimer?.cancel();
    _terminalChannelCtrl.dispose();
    _terminalGuardCtrl.dispose();
    super.dispose();
  }

  Future<void> _readSensors() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final levels = await ModbusService.readLevels();
    if (!mounted) return;
    setState(() {
      if (levels != null) {
        _levels = levels;
      } else {
        _error = 'MODBUS';
      }
      _loading = false;
    });
  }

  // Наблюдение опрашивает КАНАЛ/РЕЖИМ/ПАУЗУ прямо из полей ввода, ещё не
  // сохранённых в конфиг — так техник может подбирать параметры и сразу
  // проверять результат по журналу, не сохраняя на каждой попытке.
  void _toggleObserve() {
    if (_observing) {
      _terminalObserveTimer?.cancel();
      setState(() => _observing = false);
      return;
    }
    setState(() => _observing = true);
    _pollTerminalOnce();
    // 30 мс — тот же интервал, что и на экране оплаты (payment.dart),
    // чтобы наблюдение здесь честно показывало то же самое, что реально
    // ловит боевой опрос, а не более грубую картину.
    _terminalObserveTimer = Timer.periodic(
      const Duration(milliseconds: 30),
      (_) => _pollTerminalOnce(),
    );
  }

  Future<void> _pollTerminalOnce() async {
    // Один тик — три последовательных запроса к шине. При 30 мс между
    // тиками Timer.periodic не ждёт завершения предыдущего вызова — без
    // этой защиты тики копились бы и накладывались друг на друга,
    // а порядок печати в журнале переставал совпадать с реальным
    // порядком событий (то же самое, что и LevelService._tick).
    if (_pollingTerminal) return;
    _pollingTerminal = true;
    try {
      final channel =
          int.tryParse(_terminalChannelCtrl.text) ??
          IoModuleInputs.defaultPaymentTerminalDI;
      final guard = int.tryParse(_terminalGuardCtrl.text) ?? 3000;
      final poll = await ModbusService.pollTerminal(
        channel: channel,
        mode: _terminalMode,
        guardMs: guard,
      );
      final journal = await ModbusService.getTerminalJournal();

      // Диагностика "правильный ли канал выбран" — на случай, если карта
      // реально прошла, а на настроенном канале ничего не изменилось.
      // Намеренно ОТДЕЛЬНАЯ транзакция от pollTerminal, а не переиспользование
      // общего снимка — короткое время была версия с одним общим широким
      // чтением, но причиной пропущенных оплат оказался не лишний запрос,
      // а забытый явный таймаут на нём (см. комментарий у "pollTerminal" в
      // ModbusChannel.kt и docs/payment_terminal.md). Расхождение картинки
      // между этой диагностикой и pollTerminal в пределах пары миллисекунд
      // — не проблема, это инструмент техника, а не путь приёма денег.
      // Любое изменение на ЛЮБОМ канале печатается в лог отладки — видно
      // через adb logcat.
      final all = await ModbusService.readAllInputs();
      if (all != null) {
        final last = _lastAllChannels;
        if (last != null) {
          for (var i = 0; i < all.length && i < last.length; i++) {
            if (all[i] != last[i]) {
              debugPrint(
                'TERMINAL DEBUG: DI$i ${last[i] ? 1 : 0}→${all[i] ? 1 : 0} '
                'в ${DateTime.now().toIso8601String()}',
              );
            }
          }
        }
        _lastAllChannels = all;
      }

      if (!mounted) return;
      setState(() {
        if (poll != null) _terminalState = poll.state;
        _terminalJournal = journal;
      });
    } finally {
      _pollingTerminal = false;
    }
  }

  Future<void> _clearTerminalJournal() async {
    await ModbusService.clearTerminalJournal();
    if (!mounted) return;
    setState(() => _terminalJournal = []);
  }

  void _saveTerminalSettings() {
    final notifier = context.read<AppNotifier>();
    final t = _i18n[notifier.lang]!;
    final channel = int.tryParse(_terminalChannelCtrl.text);
    final guard = int.tryParse(_terminalGuardCtrl.text);
    if (channel == null || channel < 0 || channel >= kIoChannelCount) {
      _snack(t['err_terminal_channel']!);
      return;
    }
    if (guard == null || guard < 100) {
      _snack(t['err_terminal_guard']!);
      return;
    }
    final updated = notifier.config.copyWith(
      paymentTerminalChannel: channel,
      paymentTerminalMode: _terminalMode,
      paymentTerminalGuardMs: guard,
      paymentTerminalEnabled: _terminalEnabled,
    );
    notifier.saveConfig(updated);
    _snack(t['saved']!);
  }

  void _snack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final t = _i18n[context.watch<AppNotifier>().lang]!;
    final journal = _terminalJournal.reversed.toList(); // новые сверху

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
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            child: Text(
              _loading ? t['sensors_reading']! : t['sensors_read']!,
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
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
          final value = _levels != null && _levels!.length > i
              ? _levels![i]
              : null;
          return Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: _SensorRow(index: i, value: value, t: t),
          );
        }),

        const SizedBox(height: 28),
        Container(height: 1, color: const Color(0xFF1A2233)),
        const SizedBox(height: 20),

        Text(
          t['terminal_section']!,
          style: const TextStyle(
            color: Color(0xFF556677),
            fontWeight: FontWeight.bold,
            fontSize: 13,
          ),
        ),
        const SizedBox(height: 12),
        _ToggleRow(
          label: t['terminal_enabled']!,
          value: _terminalEnabled,
          onChanged: (v) => setState(() => _terminalEnabled = v),
        ),
        const SizedBox(height: 12),
        _Field(
          label: t['terminal_channel']!,
          controller: _terminalChannelCtrl,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        ),
        const SizedBox(height: 16),
        Text(
          t['terminal_mode']!,
          style: const TextStyle(color: Color(0xFF8899AA), fontSize: 13),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: _ModeButton(
                label: t['terminal_mode_edge']!,
                selected: _terminalMode == 'edge',
                onTap: () => setState(() => _terminalMode = 'edge'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _ModeButton(
                label: t['terminal_mode_level']!,
                selected: _terminalMode == 'level',
                onTap: () => setState(() => _terminalMode = 'level'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        _Field(
          label: t['terminal_guard']!,
          controller: _terminalGuardCtrl,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        ),
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            onPressed: _saveTerminalSettings,
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF00C6B2),
              foregroundColor: Colors.black,
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            child: Text(
              t['save']!,
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
          ),
        ),

        const SizedBox(height: 20),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: const Color(0xFF141B29),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              Text(
                '${t['terminal_state']}:',
                style: const TextStyle(color: Colors.white, fontSize: 14),
              ),
              const SizedBox(width: 8),
              Text(
                _terminalState == null
                    ? t['terminal_state_unknown']!
                    : (_terminalState!
                          ? t['terminal_state_high']!
                          : t['terminal_state_low']!),
                style: TextStyle(
                  color: _terminalState == true
                      ? const Color(0xFF00C6B2)
                      : const Color(0xFF556677),
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: OutlinedButton(
                onPressed: _toggleObserve,
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFF00C6B2),
                  side: const BorderSide(color: Color(0xFF00C6B2)),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                child: Text(
                  _observing
                      ? t['terminal_observe_stop']!
                      : t['terminal_observe_start']!,
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
            ),
            const SizedBox(width: 10),
            OutlinedButton(
              onPressed: _terminalJournal.isEmpty
                  ? null
                  : _clearTerminalJournal,
              style: OutlinedButton.styleFrom(
                foregroundColor: const Color(0xFF556677),
                side: const BorderSide(color: Color(0xFF556677)),
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              child: Text(t['terminal_journal_clear']!),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Text(
          t['terminal_journal']!,
          style: const TextStyle(
            color: Color(0xFF556677),
            fontWeight: FontWeight.bold,
            fontSize: 13,
          ),
        ),
        const SizedBox(height: 8),
        Container(
          height: 220,
          width: double.infinity,
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: const Color(0xFF141B29),
            borderRadius: BorderRadius.circular(8),
          ),
          child: journal.isEmpty
              ? Center(
                  child: Text(
                    t['terminal_journal_empty']!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      color: Color(0xFF556677),
                      fontSize: 12,
                    ),
                  ),
                )
              : ListView.builder(
                  itemCount: journal.length,
                  itemBuilder: (context, i) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Text(
                      journal[i],
                      style: const TextStyle(
                        color: Color(0xFF8899AA),
                        fontSize: 11,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ),
                ),
        ),
      ],
    );
  }
}

class _ModeButton extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _ModeButton({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 10),
        decoration: BoxDecoration(
          color: selected
              ? const Color(0xFF00C6B2).withValues(alpha: 0.15)
              : const Color(0xFF1A2233),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: selected ? const Color(0xFF00C6B2) : const Color(0xFF2E2E2E),
            width: 1.5,
          ),
        ),
        child: Text(
          label,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: selected ? const Color(0xFF00C6B2) : const Color(0xFF8899AA),
            fontWeight: FontWeight.bold,
            fontSize: 13,
          ),
        ),
      ),
    );
  }
}

class _SensorRow extends StatelessWidget {
  final int index;
  // null = ещё не прочитано; true = жидкость есть; false = пусто
  // (совпадает с соглашением ModbusService.readLevels() и _LevelBadge)
  final bool? value;
  final Map<String, String> t;

  const _SensorRow({required this.index, required this.value, required this.t});

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
            decoration: BoxDecoration(color: dotColor, shape: BoxShape.circle),
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
              color: dotColor,
              fontWeight: FontWeight.bold,
              fontSize: 13,
            ),
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
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white, fontSize: 13),
            ),
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
          Text(
            '${index + 1}. $name',
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white, fontSize: 13),
          ),
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
        Text(
          label,
          style: const TextStyle(color: Color(0xFF8899AA), fontSize: 13),
        ),
        const SizedBox(height: 6),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: const Color(0xFF1A2233),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            children: [
              _StepButton(icon: Icons.remove, onPressed: () => onChanged(-50)),
              Expanded(
                child: Text(
                  '${(priceCents / 100).toStringAsFixed(2)} €',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              _StepButton(icon: Icons.add, onPressed: () => onChanged(50)),
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
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
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
        Text(
          label,
          style: const TextStyle(color: Color(0xFF8899AA), fontSize: 13),
        ),
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
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 12,
            ),
          ),
        ),
      ],
    );
  }
}

// ============================================================
// ВКЛАДКА: СКАНЕР ШИНЫ (задача "сканер шины Modbus")
// ============================================================

// Последние введённые параметры — статические поля класса, не поля
// State. Вкладки этого сервисного меню не через TabBarView с keep-alive,
// а через ручной _buildTab()/setState — переключение всегда создаёт
// новый виджет и новый State, поэтому обычные instance-поля не пережили
// бы уход с вкладки. Задача 4.4 явно хочет сохранять последний ввод "в
// пределах запуска приложения" — статические поля переживают
// пересоздание State, но не переживают перезапуск процесса, что и нужно.
class _ScannerParams {
  static int scanFrom = 1;
  static int scanTo = 247;
  static int readSlave = 1;
  static int readFunc = ModbusFunction.readHoldingRegisters;
  static int readStartAddr = 0;
  static int readCount = 1;
  // Не BusDevice.thermo.address: это просто "с какого адреса обычно
  // начинают" дефолт общего инструмента записи, не привязан по смыслу ни
  // к одному конкретному устройству (совпадение с адресом термопары
  // случайное).
  static int writeSlave = 1;
  static String writeType = 'register'; // 'register' | 'coil'
  static int writeAddr = 0;
  static int writeValue = 0;
  // Смена Slave ID — целевой адрес = BusDevice.dio.address (совпадает с
  // существующим SLAVE_DIO, чтобы код приложения вообще не пришлось
  // менять после замены модуля). idOldAddr сюда намеренно НЕ входит: поле
  // "Текущий адрес" обязано быть пустым по умолчанию (задача "правки
  // визарда смены Slave ID по итогам живого прогона", правка 3) — на
  // общей шине есть термопара с тем же регистром 0, дефолт "1" однажды
  // уже привёл к записи в чужое устройство при тестах.
  static int idNewAddr = BusDevice.dio.address;
  // Групповая запись катушек FC15 — по умолчанию все каналы модуля на
  // адресе DIO. Только выключение: живая фаза + сухие насосы на стенде
  // делают "включить всё одним кадром" невосстановимой ошибкой одного
  // касания, а сценария, где это реально нужно, нет — ни один рабочий
  // цикл не включает насосы группой. Значение ВКЛ убрано из интерфейса
  // совсем, не просто как дефолт.
  static int fc15Slave = BusDevice.dio.address;
  static int fc15Addr = 0;
  static int fc15Count = kIoChannelCount;
  // Групповая запись регистра FC16 (один регистр, но не FC06) — для
  // устройств без FC06 (задача "Chint DDSU666: найти счётчик"). Дефолт
  // адреса — не BusDevice.energyMeter.address: пока счётчик физически
  // сидит на адресе термопары/первом свободном, а не на своём целевом;
  // техник вводит текущий адрес вручную, как и в остальных инструментах
  // записи выше.
  static int fc16Slave = 1;
  static int fc16Addr = 0;
  static int fc16Value = 0;
}

// Состояние визарда смены Slave ID между фазой 1 (запись+фиксация) и
// фазой 2 (проверка) — в SharedPreferences, а не в static-полях, как у
// _ScannerParams выше. Между фазами оператор физически идёт к стойке
// снимать и подавать питание на модуль, и сколько это займёт — неизвестно;
// планшет вполне может за это время свернуть/перезапустить приложение.
// Static-поля пережили бы пересоздание State при переключении вкладок, но
// не переживают перезапуск процесса — здесь нужно именно это (задача
// "правки визарда смены Slave ID по итогам живого прогона", правка 2).
class _SlaveIdWizardState {
  static const _keyAwaiting = 'fc_wizard_awaiting_restart';
  static const _keyOldAddr = 'fc_wizard_old_addr';
  static const _keyNewAddr = 'fc_wizard_new_addr';

  static Future<({bool awaiting, int oldAddr, int newAddr})> load() async {
    final prefs = await SharedPreferences.getInstance();
    return (
      awaiting: prefs.getBool(_keyAwaiting) ?? false,
      oldAddr: prefs.getInt(_keyOldAddr) ?? 0,
      newAddr: prefs.getInt(_keyNewAddr) ?? 0,
    );
  }

  static Future<void> save(int oldAddr, int newAddr) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyAwaiting, true);
    await prefs.setInt(_keyOldAddr, oldAddr);
    await prefs.setInt(_keyNewAddr, newAddr);
  }

  static Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keyAwaiting);
    await prefs.remove(_keyOldAddr);
    await prefs.remove(_keyNewAddr);
  }
}

// Известные адреса (BusDevice, bus_map.dart) — подписываются в
// результатах поиска, если совпали. Сами адреса живут только в
// BusDevice — здесь только их i18n-подписи для UI. Кросс-языковое
// дублирование с ModbusChannel.kt (SLAVE_DIO/SLAVE_THERMO/SLAVE_ENERGY)
// по-прежнему намеренное — см. заголовок bus_map.dart.
const Map<BusDevice, String> _knownSlaveLabels = {
  BusDevice.thermo: 'scanner_known_thermo',
  BusDevice.energyMeter: 'scanner_known_energy',
  BusDevice.dio: 'scanner_known_dio',
};
final Map<int, String> _knownSlaves = {
  for (final d in BusDevice.values) d.address: _knownSlaveLabels[d]!,
};

// Стандартные коды исключений Modbus — протокольные термины, намеренно
// не переводятся (как и "FC01" в остальном интерфейсе сканера).
const Map<int, String> _exceptionNames = {
  1: 'Illegal Function',
  2: 'Illegal Data Address',
  3: 'Illegal Data Value',
  4: 'Slave Device Failure',
  5: 'Acknowledge',
  6: 'Slave Device Busy',
  8: 'Memory Parity Error',
  10: 'Gateway Path Unavailable',
  11: 'Gateway Target Device Failed to Respond',
};

// Разумный предел на количество регистров/битов за один запрос (задача
// 1.3) — случайный ввод вроде "60000" не должен подвешивать шину надолго.
// 125 — практический потолок для регистров у большинства Modbus RTU
// реализаций (2 байта на регистр, укладывается в стандартный размер
// кадра), одно и то же значение используется и для битовых типов ради
// простоты интерфейса.
const int _scannerMaxCount = 125;

class _ScannerTab extends StatefulWidget {
  @override
  State<_ScannerTab> createState() => _ScannerTabState();
}

class _ScannerTabState extends State<_ScannerTab> {
  // --- Поиск устройств ---
  late TextEditingController _scanFromCtrl;
  late TextEditingController _scanToCtrl;
  bool _scanning = false;
  bool _scanCancelRequested = false;
  int _scanProbed = 0;
  int _scanTotal = 0;
  // Чётность для этого поиска (диагностика "чётность отличается от
  // ожидаемой", задача "Chint DDSU666: найти счётчик") — 'none' по
  // умолчанию, ничего не меняет для обычного поиска. Не persisted через
  // _ScannerParams намеренно: нештатный режим не должен пережить уход со
  // вкладки и остаться незамеченным при следующем визите.
  String _scanParity = 'none';
  final List<int> _scanFound = [];

  // --- Перебор скорости (диагностика "молчащий, но подключённый адрес")
  late TextEditingController _sweepSlaveCtrl;
  bool _sweeping = false;
  String? _sweepResultText;
  bool? _sweepOk;

  // --- Смена Slave ID (задача "правки визарда смены Slave ID по итогам
  // живого прогона") ---
  late TextEditingController _idOldCtrl;
  late TextEditingController _idNewCtrl;
  // Не персистится через _ScannerParams сознательно (в отличие от
  // остальных полей вкладки) — опасный обход опознания не должен молча
  // переживать переключение вкладок и оставаться включённым для
  // следующего технического не глядя.
  bool _skipIdentification = false;
  bool _idChanging = false;
  bool _idAwaitingRestart = false; // фаза 1 прошла, ждём снятия/подачи питания
  bool _idVerifying = false;
  final List<String> _idLog = [];
  bool? _idOk;
  bool? _idNewAddrOk;
  bool? _idOldAddrSilent;
  List<int>? _idDump;

  // --- Чтение регистров ---
  late TextEditingController _readSlaveCtrl;
  late TextEditingController _readStartCtrl;
  late TextEditingController _readCountCtrl;
  late int _readFunc;
  bool _reading = false;
  ScanReadResult? _readResult;
  int _readResultStartAddr = 0;

  // --- Запись регистра (опасно) ---
  late TextEditingController _writeSlaveCtrl;
  late TextEditingController _writeAddrCtrl;
  late TextEditingController _writeValueCtrl;
  late String _writeType;
  bool _writing = false;
  String? _writeResultText;
  bool? _writeOk;

  // --- Групповая запись катушек FC15 (только выключение) ---
  late TextEditingController _fc15SlaveCtrl;
  late TextEditingController _fc15AddrCtrl;
  late TextEditingController _fc15CountCtrl;
  bool _fc15Writing = false;
  String? _fc15ResultText;
  bool? _fc15Ok;

  // --- Групповая запись регистра FC16 (опасно) — для устройств без FC06,
  // например Chint DDSU666 (задача "Chint DDSU666: найти счётчик"). Пишет
  // ровно один регистр, но кадром FC16, а не FC06.
  late TextEditingController _fc16SlaveCtrl;
  late TextEditingController _fc16AddrCtrl;
  late TextEditingController _fc16ValueCtrl;
  bool _fc16Writing = false;
  String? _fc16ResultText;
  bool? _fc16Ok;

  @override
  void initState() {
    super.initState();
    _scanFromCtrl = TextEditingController(text: '${_ScannerParams.scanFrom}');
    _scanToCtrl = TextEditingController(text: '${_ScannerParams.scanTo}');
    _sweepSlaveCtrl = TextEditingController(text: '5');
    _idOldCtrl = TextEditingController(); // пусто по умолчанию — правка 3
    _idOldCtrl.addListener(() {
      if (mounted) setState(() {}); // перерисовать состояние кнопки записи
    });
    _idNewCtrl = TextEditingController(text: '${_ScannerParams.idNewAddr}');
    unawaited(_restoreWizardState());
    _readSlaveCtrl = TextEditingController(text: '${_ScannerParams.readSlave}');
    _readStartCtrl = TextEditingController(
      text: '${_ScannerParams.readStartAddr}',
    );
    _readCountCtrl = TextEditingController(text: '${_ScannerParams.readCount}');
    _readFunc = _ScannerParams.readFunc;
    _writeSlaveCtrl = TextEditingController(
      text: '${_ScannerParams.writeSlave}',
    );
    _writeAddrCtrl = TextEditingController(text: '${_ScannerParams.writeAddr}');
    _writeValueCtrl = TextEditingController(
      text: '${_ScannerParams.writeValue}',
    );
    _writeType = _ScannerParams.writeType;
    _fc15SlaveCtrl = TextEditingController(text: '${_ScannerParams.fc15Slave}');
    _fc15AddrCtrl = TextEditingController(text: '${_ScannerParams.fc15Addr}');
    _fc15CountCtrl = TextEditingController(text: '${_ScannerParams.fc15Count}');
    _fc16SlaveCtrl = TextEditingController(text: '${_ScannerParams.fc16Slave}');
    _fc16AddrCtrl = TextEditingController(text: '${_ScannerParams.fc16Addr}');
    _fc16ValueCtrl = TextEditingController(text: '${_ScannerParams.fc16Value}');
  }

  @override
  void dispose() {
    // Сканер работает только пока открыта вкладка — при уходе прерываем
    // перебор адресов (задача 4.2). Цикл проверяет и этот флаг, и
    // mounted на каждой итерации; уже начатый одиночный запрос (это одна
    // короткая транзакция) успеет доработать, следующая не начнётся.
    _scanCancelRequested = true;
    _scanFromCtrl.dispose();
    _scanToCtrl.dispose();
    _sweepSlaveCtrl.dispose();
    _idOldCtrl.dispose();
    _idNewCtrl.dispose();
    _readSlaveCtrl.dispose();
    _readStartCtrl.dispose();
    _readCountCtrl.dispose();
    _writeSlaveCtrl.dispose();
    _writeAddrCtrl.dispose();
    _writeValueCtrl.dispose();
    _fc15SlaveCtrl.dispose();
    _fc15AddrCtrl.dispose();
    _fc15CountCtrl.dispose();
    _fc16SlaveCtrl.dispose();
    _fc16AddrCtrl.dispose();
    _fc16ValueCtrl.dispose();
    super.dispose();
  }

  void _snack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  // ---------------- Поиск устройств ----------------

  Future<void> _startScan(Map<String, String> t) async {
    final from = int.tryParse(_scanFromCtrl.text);
    final to = int.tryParse(_scanToCtrl.text);
    if (from == null || to == null || from < 1 || to > 247 || from > to) {
      _snack('${t['scanner_scan_from']}/${t['scanner_scan_to']}: 1–247');
      return;
    }
    _ScannerParams.scanFrom = from;
    _ScannerParams.scanTo = to;
    setState(() {
      _scanning = true;
      _scanCancelRequested = false;
      _scanFound.clear();
      _scanProbed = 0;
      _scanTotal = to - from + 1;
    });

    // Нештатная чётность (диагностика "Chint DDSU666") — порт временно
    // переоткрывается на ней, сканер идёт через уже открытое соединение
    // (scanProbe своего параметра чётности не имеет). Восстановление на
    // обычные параметры — в finally, ЛЮБОЙ исход (нашли, не нашли,
    // отменили, ушли с вкладки) не должен оставить приложение без связи
    // с боевым модулем.
    final customParity = _scanParity != 'none';
    if (customParity) {
      await ModbusService.openWithParity(parity: _scanParity);
    }
    try {
      // Без своего потока (правило проекта) — обычный последовательный
      // цикл через уже существующую фоновую очередь, один короткий запрос
      // за раз. Малый таймаут (100 мс) на пробу — иначе перебор всего
      // диапазона растянулся бы на минуты (задача 2.2).
      for (var addr = from; addr <= to; addr++) {
        if (_scanCancelRequested || !mounted) break;
        final found = await ModbusService.scanProbe(
          slaveId: addr,
          timeoutMs: 100,
        );
        if (!mounted) break;
        setState(() {
          _scanProbed++;
          if (found) _scanFound.add(addr);
        });
      }
    } finally {
      if (customParity) {
        await ModbusService.openWithParity(parity: 'none');
      }
    }
    if (mounted) setState(() => _scanning = false);
  }

  void _stopScan() {
    setState(() => _scanCancelRequested = true);
  }

  // ---------------- Перебор скорости ----------------
  // Диагностика "адрес занят, но молчит на боевой скорости" — если
  // устройство отвечает на нестандартной скорости, поиск на 9600 его
  // никогда не найдёт. Порт восстанавливается на исходной скорости в
  // конце в любом случае (см. ModbusChannel.baudSweep) — независимо от
  // результата.

  Future<void> _runBaudSweep(Map<String, String> t) async {
    final slave = int.tryParse(_sweepSlaveCtrl.text);
    if (slave == null || slave < 1 || slave > 247) {
      _snack('${t['scanner_slave']}: 1–247');
      return;
    }
    setState(() {
      _sweeping = true;
      _sweepResultText = null;
      _sweepOk = null;
    });
    final found = await ModbusService.baudSweep(slaveId: slave);
    if (!mounted) return;
    setState(() {
      _sweeping = false;
      _sweepOk = found != null;
      _sweepResultText = found != null
          ? '${t['scanner_sweep_found']}: $found'
          : t['scanner_sweep_not_found'];
    });
  }

  // ---------------- Смена Slave ID ----------------

  int? _idSavedOldAddr;
  int? _idSavedNewAddr;

  // Восстановление состояния визарда после сворачивания/перезапуска
  // приложения — правка 2: оператор уходит к стойке снимать/подавать
  // питание, визард должен ждать его на том же шаге, а не терять контекст.
  Future<void> _restoreWizardState() async {
    final saved = await _SlaveIdWizardState.load();
    if (!mounted || !saved.awaiting) return;
    setState(() {
      _idOldCtrl.text = '${saved.oldAddr}';
      _idNewCtrl.text = '${saved.newAddr}';
      _idSavedOldAddr = saved.oldAddr;
      _idSavedNewAddr = saved.newAddr;
      _idAwaitingRestart = true;
      _idLog.add(
        'Состояние восстановлено: ожидание перезапуска питания модуля '
        '(адрес ${saved.oldAddr} → ${saved.newAddr}).',
      );
    });
  }

  Future<void> _confirmAndChangeSlaveId(Map<String, String> t) async {
    final oldAddr = int.tryParse(_idOldCtrl.text);
    final newAddr = int.tryParse(_idNewCtrl.text);
    if (oldAddr == null || oldAddr < 1 || oldAddr > 255) {
      _snack('${t['scanner_id_old']}: 1–255');
      return;
    }
    if (newAddr == null || newAddr < 1 || newAddr > 255) {
      _snack('${t['scanner_id_new']}: 1–255');
      return;
    }

    // Правка 3.6 — адреса цифрами, без общей формулировки: "Записать
    // адрес 5 в устройство на адресе 1".
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF141B29),
        title: Text(
          t['scanner_id_confirm_title']!,
          style: const TextStyle(color: Colors.white),
        ),
        content: Text(
          '${t['scanner_id_confirm_write']} $newAddr '
          '${t['scanner_id_confirm_into']} $oldAddr'
          '${_skipIdentification ? '\n\n${t['scanner_id_skip']}!' : ''}',
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(
              t['scanner_write_confirm_cancel']!,
              style: const TextStyle(color: Color(0xFF8899AA)),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(
              t['scanner_id_btn']!,
              style: const TextStyle(
                color: Color(0xFFE53935),
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    _ScannerParams.idNewAddr = newAddr;

    setState(() {
      _idChanging = true;
      _idLog.clear();
      _idAwaitingRestart = false;
      _idOk = null;
      _idNewAddrOk = null;
      _idOldAddrSilent = null;
      _idDump = null;
    });

    final result = await ModbusService.changeSlaveIdPhase1(
      oldAddr: oldAddr,
      newAddr: newAddr,
      skipIdentification: _skipIdentification,
    );

    if (!mounted) return;

    if (result.ok) {
      await _SlaveIdWizardState.save(oldAddr, newAddr);
      _idSavedOldAddr = oldAddr;
      _idSavedNewAddr = newAddr;
    }

    setState(() {
      _idChanging = false;
      _idAwaitingRestart = result.ok;
      // Пока идёт ожидание перезапуска — итог ещё не определён (граница
      // журнала нейтральная); отказ фазы 1 (заблокировано опознанием или
      // реальная ошибка записи) — сразу красный.
      _idOk = result.ok ? null : false;
      _idLog.addAll(result.log);
    });
  }

  Future<void> _continuePhase2(Map<String, String> t) async {
    final oldAddr = _idSavedOldAddr;
    final newAddr = _idSavedNewAddr;
    if (oldAddr == null || newAddr == null) return;

    setState(() => _idVerifying = true);
    final r = await ModbusService.changeSlaveIdPhase2(
      oldAddr: oldAddr,
      newAddr: newAddr,
    );
    if (!mounted) return;
    await _SlaveIdWizardState.clear();
    setState(() {
      _idVerifying = false;
      _idAwaitingRestart = false;
      _idOk = r.ok;
      _idNewAddrOk = r.newAddrOk;
      _idOldAddrSilent = r.oldAddrSilent;
      _idDump = r.dump;
      _idLog.addAll(r.log);
    });
  }

  Future<void> _cancelAwaitingRestart() async {
    await _SlaveIdWizardState.clear();
    if (!mounted) return;
    setState(() {
      _idAwaitingRestart = false;
      _idSavedOldAddr = null;
      _idSavedNewAddr = null;
    });
  }

  // ---------------- Чтение регистров ----------------

  Future<void> _read(Map<String, String> t) async {
    final slave = int.tryParse(_readSlaveCtrl.text);
    final start = int.tryParse(_readStartCtrl.text);
    final count = int.tryParse(_readCountCtrl.text);
    if (slave == null || slave < 1 || slave > 247) {
      _snack('${t['scanner_slave']}: 1–247');
      return;
    }
    if (start == null || start < 0 || start > 65535) {
      _snack('${t['scanner_start_addr']}: 0–65535');
      return;
    }
    if (count == null || count < 1 || count > _scannerMaxCount) {
      _snack('${t['scanner_count']}: 1–$_scannerMaxCount');
      return;
    }
    _ScannerParams.readSlave = slave;
    _ScannerParams.readFunc = _readFunc;
    _ScannerParams.readStartAddr = start;
    _ScannerParams.readCount = count;
    setState(() {
      _reading = true;
      _readResult = null;
    });
    final result = await ModbusService.scanRead(
      slaveId: slave,
      funcCode: _readFunc,
      startAddr: start,
      count: count,
    );
    if (!mounted) return;
    setState(() {
      _readResult = result;
      _readResultStartAddr = start;
      _reading = false;
    });
  }

  // ---------------- Запись регистра (опасно) ----------------

  Future<void> _confirmAndWrite(Map<String, String> t) async {
    final slave = int.tryParse(_writeSlaveCtrl.text);
    final addr = int.tryParse(_writeAddrCtrl.text);
    final value = int.tryParse(_writeValueCtrl.text);
    if (slave == null || slave < 1 || slave > 247) {
      _snack('${t['scanner_slave']}: 1–247');
      return;
    }
    if (addr == null || addr < 0 || addr > 65535) {
      _snack('${t['scanner_write_addr']}: 0–65535');
      return;
    }
    final maxValue = _writeType == 'coil' ? 1 : 65535;
    if (value == null || value < 0 || value > maxValue) {
      _snack('${t['scanner_write_value']}: 0–$maxValue');
      return;
    }

    // Подтверждение с точным показом, что и куда будет записано (задача
    // 3.3) — неверная запись в служебный регистр способна сделать
    // устройство недоступным.
    final typeLabel = _writeType == 'coil'
        ? t['scanner_write_type_coil']!
        : t['scanner_write_type_register']!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF141B29),
        title: Text(
          t['scanner_write_confirm_title']!,
          style: const TextStyle(color: Colors.white),
        ),
        content: Text(
          '${t['scanner_slave']}: $slave\n$typeLabel #$addr ← $value',
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(
              t['scanner_write_confirm_cancel']!,
              style: const TextStyle(color: Color(0xFF8899AA)),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(
              t['scanner_write_btn']!,
              style: const TextStyle(
                color: Color(0xFFE53935),
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    _ScannerParams.writeSlave = slave;
    _ScannerParams.writeType = _writeType;
    _ScannerParams.writeAddr = addr;
    _ScannerParams.writeValue = value;

    setState(() {
      _writing = true;
      _writeResultText = null;
      _writeOk = null;
    });

    final ok = _writeType == 'coil'
        ? await ModbusService.scanWriteCoil(
            slaveId: slave,
            addr: addr,
            value: value == 1,
          )
        : await ModbusService.scanWriteRegister(
            slaveId: slave,
            addr: addr,
            value: value,
          );

    if (!mounted) return;
    if (!ok) {
      setState(() {
        _writing = false;
        _writeOk = false;
        _writeResultText = t['scanner_write_result_fail'];
      });
      return;
    }

    // Перечитать тот же регистр и показать результат (задача 3.4).
    final readBack = _writeType == 'coil'
        ? await ModbusService.scanRead(
            slaveId: slave,
            funcCode: 0x01,
            startAddr: addr,
            count: 1,
          )
        : await ModbusService.scanRead(
            slaveId: slave,
            funcCode: 0x03,
            startAddr: addr,
            count: 1,
          );

    if (!mounted) return;
    setState(() {
      _writing = false;
      _writeOk = true;
      final readBackValue = readBack.status != 'ok'
          ? '—'
          : (_writeType == 'coil'
                ? (readBack.boolValues?.first == true ? '1' : '0')
                : readBack.intValues?.first.toString() ?? '—');
      _writeResultText =
          '${t['scanner_write_result_readback']}: $readBackValue';
    });
  }

  // ---------------- Групповая запись катушек FC15 (опасно) ----------------

  Future<void> _confirmAndWriteMultipleCoils(Map<String, String> t) async {
    final slave = int.tryParse(_fc15SlaveCtrl.text);
    final addr = int.tryParse(_fc15AddrCtrl.text);
    final count = int.tryParse(_fc15CountCtrl.text);
    if (slave == null || slave < 1 || slave > 247) {
      _snack('${t['scanner_slave']}: 1–247');
      return;
    }
    if (addr == null || addr < 0 || addr > 65535) {
      _snack('${t['scanner_write_addr']}: 0–65535');
      return;
    }
    if (count == null || count < 1 || count > _scannerMaxCount) {
      _snack('${t['scanner_count']}: 1–$_scannerMaxCount');
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF141B29),
        title: Text(
          t['scanner_write_confirm_title']!,
          style: const TextStyle(color: Colors.white),
        ),
        content: Text(
          '${t['scanner_slave']}: $slave\n'
          'FC15 #$addr..${addr + count - 1} ← ${t['scanner_fc15_off']!}',
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(
              t['scanner_write_confirm_cancel']!,
              style: const TextStyle(color: Color(0xFF8899AA)),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(
              t['scanner_write_btn']!,
              style: const TextStyle(
                color: Color(0xFFE53935),
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    _ScannerParams.fc15Slave = slave;
    _ScannerParams.fc15Addr = addr;
    _ScannerParams.fc15Count = count;

    setState(() {
      _fc15Writing = true;
      _fc15ResultText = null;
      _fc15Ok = null;
    });

    // Только нули — переключателя на включение в интерфейсе нет и не
    // будет (см. комментарий у _ScannerParams).
    final values = List<bool>.filled(count, false);
    final r = await ModbusService.scanWriteMultipleCoils(
      slaveId: slave,
      addr: addr,
      values: values,
    );

    if (!mounted) return;
    setState(() {
      _fc15Writing = false;
      _fc15Ok = r.status == 'ok';
      _fc15ResultText = switch (r.status) {
        'ok' => t['scanner_fc15_ok']!,
        'exception' =>
          '${t['scanner_err_exception']}: ${r.exceptionCode} '
              '(${_exceptionNames[r.exceptionCode] ?? '?'})',
        'bad_crc' => t['scanner_err_bad_crc']!,
        _ => t['scanner_err_no_response']!,
      };
    });
  }

  // ---------------- Групповая запись регистра FC16 (опасно) ----------------
  // Для устройств без FC06 (задача "Chint DDSU666: найти счётчик" — по
  // мануалу у счётчика есть только 03 на чтение и 16 на запись, даже для
  // одного регистра). Пишет ровно один регистр, но кадром FC16.

  Future<void> _confirmAndWriteMultipleRegisters(Map<String, String> t) async {
    final slave = int.tryParse(_fc16SlaveCtrl.text);
    final addr = int.tryParse(_fc16AddrCtrl.text);
    final value = int.tryParse(_fc16ValueCtrl.text);
    if (slave == null || slave < 1 || slave > 247) {
      _snack('${t['scanner_slave']}: 1–247');
      return;
    }
    if (addr == null || addr < 0 || addr > 65535) {
      _snack('${t['scanner_write_addr']}: 0–65535');
      return;
    }
    if (value == null || value < 0 || value > 65535) {
      _snack('${t['scanner_write_value']}: 0–65535');
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF141B29),
        title: Text(
          t['scanner_write_confirm_title']!,
          style: const TextStyle(color: Colors.white),
        ),
        content: Text(
          '${t['scanner_slave']}: $slave\nFC16 #$addr ← $value',
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(
              t['scanner_write_confirm_cancel']!,
              style: const TextStyle(color: Color(0xFF8899AA)),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(
              t['scanner_write_btn']!,
              style: const TextStyle(
                color: Color(0xFFE53935),
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    _ScannerParams.fc16Slave = slave;
    _ScannerParams.fc16Addr = addr;
    _ScannerParams.fc16Value = value;

    setState(() {
      _fc16Writing = true;
      _fc16ResultText = null;
      _fc16Ok = null;
    });

    // Одна попытка, без автоповторов (правило проекта: повторная слепая
    // запись способна оставить устройство в состоянии, которое потом
    // трудно разобрать) — та же дисциплина, что и у FC15 выше.
    final r = await ModbusService.scanWriteMultipleRegisters(
      slaveId: slave,
      addr: addr,
      values: [value],
    );

    if (!mounted) return;
    if (r.status != 'ok') {
      setState(() {
        _fc16Writing = false;
        _fc16Ok = false;
        _fc16ResultText = switch (r.status) {
          'exception' =>
            '${t['scanner_err_exception']}: ${r.exceptionCode} '
                '(${_exceptionNames[r.exceptionCode] ?? '?'})',
          'bad_crc' => t['scanner_err_bad_crc']!,
          _ => t['scanner_err_no_response']!,
        };
      });
      return;
    }

    // Перечитать тот же регистр и показать результат — той же логикой,
    // что и одиночная запись FC06 выше.
    final readBack = await ModbusService.scanRead(
      slaveId: slave,
      funcCode: 0x03,
      startAddr: addr,
      count: 1,
    );

    if (!mounted) return;
    setState(() {
      _fc16Writing = false;
      _fc16Ok = true;
      final readBackValue = readBack.status != 'ok'
          ? '—'
          : readBack.intValues?.first.toString() ?? '—';
      _fc16ResultText = '${t['scanner_write_result_readback']}: $readBackValue';
    });
  }

  @override
  Widget build(BuildContext context) {
    final t = _i18n[context.watch<AppNotifier>().lang]!;

    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        // ---------------- Поиск устройств ----------------
        Text(
          t['scanner_scan_section']!,
          style: const TextStyle(
            color: Color(0xFF556677),
            fontWeight: FontWeight.bold,
            fontSize: 13,
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: _Field(
                label: t['scanner_scan_from']!,
                controller: _scanFromCtrl,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _Field(
                label: t['scanner_scan_to']!,
                controller: _scanToCtrl,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Text(
          t['scanner_scan_parity']!,
          style: const TextStyle(color: Color(0xFF8899AA), fontSize: 13),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: _ModeButton(
                label: t['scanner_parity_none']!,
                selected: _scanParity == 'none',
                onTap: () => setState(() => _scanParity = 'none'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _ModeButton(
                label: t['scanner_parity_odd']!,
                selected: _scanParity == 'odd',
                onTap: () => setState(() => _scanParity = 'odd'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _ModeButton(
                label: t['scanner_parity_even']!,
                selected: _scanParity == 'even',
                onTap: () => setState(() => _scanParity = 'even'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            onPressed: _scanning ? _stopScan : () => _startScan(t),
            style: ElevatedButton.styleFrom(
              backgroundColor: _scanning
                  ? const Color(0xFF556677)
                  : const Color(0xFF00C6B2),
              foregroundColor: Colors.black,
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            child: Text(
              _scanning ? t['scanner_scan_stop']! : t['scanner_scan_start']!,
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
          ),
        ),
        if (_scanning || _scanProbed > 0) ...[
          const SizedBox(height: 10),
          Text(
            '${t['scanner_scan_progress']}: $_scanProbed / $_scanTotal',
            style: const TextStyle(color: Color(0xFF8899AA), fontSize: 13),
          ),
        ],
        const SizedBox(height: 12),
        if (_scanFound.isEmpty && !_scanning)
          Text(
            t['scanner_scan_empty']!,
            style: const TextStyle(color: Color(0xFF556677), fontSize: 13),
          )
        else
          ..._scanFound.map((addr) {
            final knownKey = _knownSlaves[addr];
            return Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: const Color(0xFF141B29),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Text(
                    '$addr',
                    style: const TextStyle(
                      color: Color(0xFF00C6B2),
                      fontWeight: FontWeight.bold,
                      fontSize: 15,
                    ),
                  ),
                  if (knownKey != null) ...[
                    const SizedBox(width: 10),
                    Text(
                      t[knownKey]!,
                      style: const TextStyle(
                        color: Color(0xFF8899AA),
                        fontSize: 13,
                      ),
                    ),
                  ],
                ],
              ),
            );
          }),

        const SizedBox(height: 20),
        Text(
          t['scanner_sweep_hint']!,
          style: const TextStyle(color: Color(0xFF556677), fontSize: 12),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            SizedBox(
              width: 120,
              child: _Field(
                label: t['scanner_slave']!,
                controller: _sweepSlaveCtrl,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(top: 20),
                child: OutlinedButton(
                  onPressed: _sweeping ? null : () => _runBaudSweep(t),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFF00C6B2),
                    side: const BorderSide(color: Color(0xFF00C6B2)),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  child: Text(
                    t['scanner_sweep_btn']!,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
              ),
            ),
          ],
        ),
        if (_sweepResultText != null) ...[
          const SizedBox(height: 10),
          Text(
            _sweepResultText!,
            style: TextStyle(
              color: _sweepOk == true
                  ? const Color(0xFF00C6B2)
                  : const Color(0xFFE53935),
              fontSize: 13,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],

        const SizedBox(height: 28),
        Container(height: 1, color: const Color(0xFF1A2233)),
        const SizedBox(height: 20),

        // ---------------- Смена Slave ID (CWT-BK-1616T-S) ----------------
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: const Color(0xFFE53935).withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: const Color(0xFFE53935).withValues(alpha: 0.4),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                t['scanner_id_section']!,
                style: const TextStyle(
                  color: Color(0xFFE53935),
                  fontWeight: FontWeight.bold,
                  fontSize: 13,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                t['scanner_id_warning']!,
                style: const TextStyle(
                  color: Color(0xFFE53935),
                  fontSize: 12,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      t['scanner_id_skip']!,
                      style: const TextStyle(
                        color: Color(0xFFE53935),
                        fontSize: 13,
                      ),
                    ),
                  ),
                  Switch(
                    value: _skipIdentification,
                    onChanged: (_idChanging || _idAwaitingRestart)
                        ? null
                        : (v) => setState(() => _skipIdentification = v),
                    activeThumbColor: const Color(0xFFE53935),
                  ),
                ],
              ),
              Text(
                t['scanner_id_skip_hint']!,
                style: const TextStyle(
                  color: Color(0xFF8899AA),
                  fontSize: 11,
                  height: 1.3,
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: _Field(
                      label: t['scanner_id_old']!,
                      controller: _idOldCtrl,
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _Field(
                      label: t['scanner_id_new']!,
                      controller: _idNewCtrl,
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed:
                      (_idChanging ||
                          _idAwaitingRestart ||
                          _idOldCtrl.text.trim().isEmpty)
                      ? null
                      : () => _confirmAndChangeSlaveId(t),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFE53935),
                    foregroundColor: Colors.white,
                    disabledBackgroundColor: const Color(
                      0xFFE53935,
                    ).withValues(alpha: 0.3),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  child: Text(
                    t['scanner_id_btn']!,
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                  ),
                ),
              ),
              if (_idLog.isNotEmpty) ...[
                const SizedBox(height: 16),
                Container(
                  width: double.infinity,
                  constraints: const BoxConstraints(maxHeight: 220),
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: const Color(0xFF141B29),
                    borderRadius: BorderRadius.circular(8),
                    // Итог последней проверки (сразу после фазы 1 или
                    // после фазы 2) — подсветка рамки журнала, без
                    // дублирования текста: сам итог уже читается по
                    // последней строке лога.
                    border: _idOk == null
                        ? null
                        : Border.all(
                            color: _idOk == true
                                ? const Color(0xFF00C6B2)
                                : const Color(0xFFE53935),
                          ),
                  ),
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        for (final line in _idLog)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 2),
                            child: Text(
                              line,
                              style: const TextStyle(
                                color: Color(0xFF8899AA),
                                fontSize: 12,
                                fontFamily: 'monospace',
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
              if (_idNewAddrOk == true) ...[
                const SizedBox(height: 12),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: const Color(0xFF00C6B2).withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: const Color(0xFF00C6B2).withValues(alpha: 0.4),
                    ),
                  ),
                  child: Text(
                    t['scanner_id_new_addr_confirmed']!,
                    style: const TextStyle(
                      color: Color(0xFF00C6B2),
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
              // Правка 2 — отдельная явная ошибка, если старый адрес всё
              // ещё отвечает после смены: не полагаемся на то, что технику
              // не лень дочитать журнал до конца.
              if (_idOldAddrSilent == false) ...[
                const SizedBox(height: 12),
                _ScanErrorBox(text: t['scanner_id_old_still_responds']!),
              ],
              // Фаза 1 прошла — ждём, пока оператор снимет/подаст питание
              // на модуль. Единственный способ двинуться дальше — кнопка
              // "Продолжить проверку", никаких таймеров (правка 2).
              if (_idAwaitingRestart) ...[
                const SizedBox(height: 16),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: const Color(0xFF00C6B2).withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: const Color(0xFF00C6B2).withValues(alpha: 0.4),
                    ),
                  ),
                  child: Text(
                    t['scanner_id_power_cycle_hint']!,
                    style: const TextStyle(
                      color: Color(0xFF00C6B2),
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                      height: 1.4,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton(
                    onPressed: _idVerifying ? null : () => _continuePhase2(t),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFF00C6B2),
                      side: const BorderSide(color: Color(0xFF00C6B2)),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                    child: Text(
                      t['scanner_id_verify_btn']!,
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
                if (!_idVerifying) ...[
                  const SizedBox(height: 8),
                  Center(
                    child: TextButton(
                      onPressed: _cancelAwaitingRestart,
                      child: Text(
                        t['scanner_id_cancel_wait']!,
                        style: const TextStyle(color: Color(0xFF8899AA)),
                      ),
                    ),
                  ),
                ],
              ],
              if (_idDump != null) ...[
                const SizedBox(height: 16),
                Text(
                  t['scanner_id_dump_title']!,
                  style: const TextStyle(
                    color: Color(0xFF8899AA),
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 8),
                _ScanReadResultView(
                  result: ScanReadResult(status: 'ok', intValues: _idDump),
                  t: t,
                  startAddr: 0,
                ),
              ],
            ],
          ),
        ),

        const SizedBox(height: 28),
        Container(height: 1, color: const Color(0xFF1A2233)),
        const SizedBox(height: 20),

        // ---------------- Чтение регистров ----------------
        Text(
          t['scanner_read_section']!,
          style: const TextStyle(
            color: Color(0xFF556677),
            fontWeight: FontWeight.bold,
            fontSize: 13,
          ),
        ),
        const SizedBox(height: 12),
        _Field(
          label: t['scanner_slave']!,
          controller: _readSlaveCtrl,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        ),
        const SizedBox(height: 12),
        Text(
          t['scanner_func']!,
          style: const TextStyle(color: Color(0xFF8899AA), fontSize: 13),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            SizedBox(
              width: 260,
              child: _ModeButton(
                label: t['scanner_func_coils']!,
                selected: _readFunc == 0x01,
                onTap: () => setState(() => _readFunc = 0x01),
              ),
            ),
            SizedBox(
              width: 260,
              child: _ModeButton(
                label: t['scanner_func_discrete']!,
                selected: _readFunc == 0x02,
                onTap: () => setState(() => _readFunc = 0x02),
              ),
            ),
            SizedBox(
              width: 260,
              child: _ModeButton(
                label: t['scanner_func_holding']!,
                selected: _readFunc == 0x03,
                onTap: () => setState(() => _readFunc = 0x03),
              ),
            ),
            SizedBox(
              width: 260,
              child: _ModeButton(
                label: t['scanner_func_input']!,
                selected: _readFunc == 0x04,
                onTap: () => setState(() => _readFunc = 0x04),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: _Field(
                label: t['scanner_start_addr']!,
                controller: _readStartCtrl,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _Field(
                label: t['scanner_count']!,
                controller: _readCountCtrl,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            onPressed: _reading ? null : () => _read(t),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF00C6B2),
              foregroundColor: Colors.black,
              padding: const EdgeInsets.symmetric(vertical: 14),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            child: Text(
              t['scanner_read_btn']!,
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
            ),
          ),
        ),
        const SizedBox(height: 16),
        if (_readResult != null)
          _ScanReadResultView(
            result: _readResult!,
            t: t,
            startAddr: _readResultStartAddr,
          ),

        const SizedBox(height: 28),
        Container(height: 1, color: const Color(0xFF1A2233)),
        const SizedBox(height: 20),

        // ---------------- Запись (опасно) ----------------
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: const Color(0xFFE53935).withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: const Color(0xFFE53935).withValues(alpha: 0.4),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                t['scanner_write_section']!,
                style: const TextStyle(
                  color: Color(0xFFE53935),
                  fontWeight: FontWeight.bold,
                  fontSize: 13,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                t['scanner_write_warning']!,
                style: const TextStyle(
                  color: Color(0xFFE53935),
                  fontSize: 12,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 16),
              _Field(
                label: t['scanner_slave']!,
                controller: _writeSlaveCtrl,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              ),
              const SizedBox(height: 12),
              Text(
                t['scanner_write_type']!,
                style: const TextStyle(color: Color(0xFF8899AA), fontSize: 13),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: _ModeButton(
                      label: t['scanner_write_type_register']!,
                      selected: _writeType == 'register',
                      onTap: () => setState(() => _writeType = 'register'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: _ModeButton(
                      label: t['scanner_write_type_coil']!,
                      selected: _writeType == 'coil',
                      onTap: () => setState(() => _writeType = 'coil'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: _Field(
                      label: t['scanner_write_addr']!,
                      controller: _writeAddrCtrl,
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _Field(
                      label: t['scanner_write_value']!,
                      controller: _writeValueCtrl,
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _writing ? null : () => _confirmAndWrite(t),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFE53935),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  child: Text(
                    t['scanner_write_btn']!,
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                  ),
                ),
              ),
              if (_writeResultText != null) ...[
                const SizedBox(height: 12),
                Text(
                  _writeResultText!,
                  style: TextStyle(
                    color: _writeOk == true
                        ? const Color(0xFF00C6B2)
                        : const Color(0xFFE53935),
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ],
          ),
        ),

        const SizedBox(height: 20),
        // ---------------- FC16: групповая запись регистра (опасно) ----------------
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: const Color(0xFFE53935).withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: const Color(0xFFE53935).withValues(alpha: 0.4),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                t['scanner_fc16_section']!,
                style: const TextStyle(
                  color: Color(0xFFE53935),
                  fontWeight: FontWeight.bold,
                  fontSize: 13,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                t['scanner_fc16_warning']!,
                style: const TextStyle(
                  color: Color(0xFFE53935),
                  fontSize: 12,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 16),
              _Field(
                label: t['scanner_slave']!,
                controller: _fc16SlaveCtrl,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: _Field(
                      label: t['scanner_write_addr']!,
                      controller: _fc16AddrCtrl,
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _Field(
                      label: t['scanner_write_value']!,
                      controller: _fc16ValueCtrl,
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFE53935),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  onPressed: _fc16Writing
                      ? null
                      : () => _confirmAndWriteMultipleRegisters(t),
                  child: Text(
                    t['scanner_fc16_btn']!,
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                  ),
                ),
              ),
              if (_fc16ResultText != null) ...[
                const SizedBox(height: 12),
                Text(
                  _fc16ResultText!,
                  style: TextStyle(
                    color: _fc16Ok == true
                        ? const Color(0xFF00C6B2)
                        : const Color(0xFFE53935),
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ],
          ),
        ),

        const SizedBox(height: 20),
        // ---------------- FC15: групповая запись катушек (опасно) ----------------
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: const Color(0xFFE53935).withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: const Color(0xFFE53935).withValues(alpha: 0.4),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                t['scanner_fc15_section']!,
                style: const TextStyle(
                  color: Color(0xFFE53935),
                  fontWeight: FontWeight.bold,
                  fontSize: 13,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                t['scanner_fc15_warning']!,
                style: const TextStyle(
                  color: Color(0xFFE53935),
                  fontSize: 12,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 16),
              _Field(
                label: t['scanner_slave']!,
                controller: _fc15SlaveCtrl,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: _Field(
                      label: t['scanner_write_addr']!,
                      controller: _fc15AddrCtrl,
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _Field(
                      label: t['scanner_count']!,
                      controller: _fc15CountCtrl,
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              // Только выключение — переключателя на "все ВКЛ" здесь
              // намеренно нет (см. комментарий у _ScannerParams.fc15Slave).
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  vertical: 12,
                  horizontal: 10,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xFF00C6B2).withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: const Color(0xFF00C6B2),
                    width: 1.5,
                  ),
                ),
                child: Text(
                  t['scanner_fc15_off']!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Color(0xFF00C6B2),
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _fc15Writing
                      ? null
                      : () => _confirmAndWriteMultipleCoils(t),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFE53935),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  child: Text(
                    t['scanner_fc15_btn']!,
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                  ),
                ),
              ),
              if (_fc15ResultText != null) ...[
                const SizedBox(height: 12),
                Text(
                  _fc15ResultText!,
                  style: TextStyle(
                    color: _fc15Ok == true
                        ? const Color(0xFF00C6B2)
                        : const Color(0xFFE53935),
                    fontSize: 13,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ],
          ),
        ),

        const SizedBox(height: 20),
        if (_scanFound.isNotEmpty ||
            _readResult != null ||
            _writeResultText != null)
          OutlinedButton(
            onPressed: () => setState(() {
              _scanFound.clear();
              _scanProbed = 0;
              _scanTotal = 0;
              _readResult = null;
              _writeResultText = null;
              _writeOk = null;
            }),
            style: OutlinedButton.styleFrom(
              foregroundColor: const Color(0xFF556677),
              side: const BorderSide(color: Color(0xFF556677)),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            child: Text(t['scanner_clear']!),
          ),
      ],
    );
  }
}

// Таблица результата scanRead: адрес/десятичное/hex/знаковое для
// регистров (задача 1.4/1.5), наглядные бейджи для битовых типов
// (задача 1.6), текст ошибки вместо пустой таблицы (задача 1.7).
class _ScanReadResultView extends StatelessWidget {
  final ScanReadResult result;
  final Map<String, String> t;
  final int startAddr;

  const _ScanReadResultView({
    required this.result,
    required this.t,
    required this.startAddr,
  });

  @override
  Widget build(BuildContext context) {
    if (result.status == 'no_response') {
      return _ScanErrorBox(text: t['scanner_err_no_response']!);
    }
    if (result.status == 'bad_crc') {
      return _ScanErrorBox(text: t['scanner_err_bad_crc']!);
    }
    if (result.status == 'exception') {
      final code = result.exceptionCode;
      final name = code != null ? _exceptionNames[code] : null;
      final text =
          '${t['scanner_err_exception']}: '
          '$code${name != null ? ' ($name)' : ''}';
      return _ScanErrorBox(text: text);
    }

    if (result.boolValues != null) {
      final values = result.boolValues!;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < values.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                children: [
                  SizedBox(
                    width: 70,
                    child: Text(
                      '${startAddr + i}',
                      style: const TextStyle(
                        color: Color(0xFF8899AA),
                        fontSize: 13,
                      ),
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: values[i]
                          ? const Color(0xFF00C6B2).withValues(alpha: 0.15)
                          : const Color(0xFF1A2233),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      values[i] ? t['scanner_bit_on']! : t['scanner_bit_off']!,
                      style: TextStyle(
                        color: values[i]
                            ? const Color(0xFF00C6B2)
                            : const Color(0xFF556677),
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      );
    }

    final values = result.intValues ?? const [];
    return Table(
      columnWidths: const {
        0: FlexColumnWidth(1),
        1: FlexColumnWidth(1.2),
        2: FlexColumnWidth(1),
        3: FlexColumnWidth(1.2),
      },
      children: [
        TableRow(
          children: [
            _scanCell(t['scanner_result_addr']!, header: true),
            _scanCell(t['scanner_result_dec']!, header: true),
            _scanCell(t['scanner_result_hex']!, header: true),
            _scanCell(t['scanner_result_signed']!, header: true),
          ],
        ),
        for (var i = 0; i < values.length; i++)
          TableRow(
            children: [
              _scanCell('${startAddr + i}'),
              _scanCell('${values[i]}'),
              _scanCell(
                '0x${values[i].toRadixString(16).padLeft(4, '0').toUpperCase()}',
              ),
              _scanCell('${values[i] > 32767 ? values[i] - 65536 : values[i]}'),
            ],
          ),
      ],
    );
  }

  Widget _scanCell(String text, {bool header = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
      child: Text(
        text,
        style: TextStyle(
          color: header ? const Color(0xFF556677) : Colors.white,
          fontWeight: header ? FontWeight.bold : FontWeight.normal,
          fontSize: 13,
        ),
      ),
    );
  }
}

class _ScanErrorBox extends StatelessWidget {
  final String text;

  const _ScanErrorBox({required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFE53935).withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        text,
        style: const TextStyle(
          color: Color(0xFFE53935),
          fontSize: 13,
          fontWeight: FontWeight.bold,
        ),
      ),
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
    'app_started_after_crash': 'Запуск после аварийного завершения',
    'service_login_ok': 'Вход в сервисное меню',
    'unauthorized_access': 'Несанкционированный доступ',
    'master_code_used': 'Использован мастер-код',
    'factory_reset': 'Сброс к заводским',
    'low_liquid': 'Заканчивается жидкость',
    'liquid_restored': 'Канистра заправлена',
    'session_complete': 'Сессия завершена',
    'hardware_error': 'Ошибка оборудования',
    'energy_reading': 'Показания энергии',
    'command_executed': 'Выполнена команда',
    'config_changed': 'Изменены настройки',
    'unexpected_payment': 'Оплата вне экрана оплаты',
    'debug_mode_changed': 'Отладочный режим',
    'out_of_service': 'ВЫВЕДЕН ИЗ ОБСЛУЖИВАНИЯ',
    'out_of_service_restored': 'Вывод из обслуживания восстановлен при старте',
    'out_of_service_cleared': 'Вывод из обслуживания снят',
    'out_of_service_trial': 'Пробный цикл',
    'payment_abandoned': 'Оплата не завершена (внесённая сумма)',
    'duplicate_payment': 'ПОВТОРНАЯ ОПЛАТА (клиент заплатил дважды)',
  };

  static const _alarmTypes = {
    'unauthorized_access',
    'master_code_used',
    'factory_reset',
    'hardware_error',
    'app_started_after_crash',
    'unexpected_payment',
    'duplicate_payment',
    'out_of_service',
    'out_of_service_restored',
  };

  static const _warnTypes = {'low_liquid'};

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
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Отправка выполнена')));
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
                style: const TextStyle(color: Color(0xFF556677), fontSize: 12),
              ),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
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

// ============================================================
// ВКЛАДКА: ОБЛАКО
// ============================================================

class _CloudTab extends StatefulWidget {
  @override
  State<_CloudTab> createState() => _CloudTabState();
}

class _CloudTabState extends State<_CloudTab> {
  late TextEditingController _deviceIdCtrl;
  late TextEditingController _urlCtrl;
  late TextEditingController _keyCtrl;
  late TextEditingController _tokenCtrl;
  late bool _enabled;
  bool _testing = false;
  // Удалённая диагностика (R1): отправка пакета и история команд.
  bool _diagBusy = false;
  List<Map<String, dynamic>> _commands = const [];
  // Обновление приложения (R2): версия, резерв, итог последнего обновления.
  Map<String, dynamic> _upd = const {};
  bool? _adb;

  Future<void> _loadUpdate() async {
    final st = await UpdateService.status();
    if (mounted) {
      setState(() {
        _upd = st;
        _adb = UpdateService.adbNetwork;
      });
    }
  }

  Future<void> _rollback() async {
    final notifier = context.read<AppNotifier>();
    final t = _i18n[notifier.lang]!;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A2233),
        title: Text(
          t['up_rollback_title']!,
          style: const TextStyle(color: Colors.white),
        ),
        content: Text(
          t['up_rollback_body']!,
          style: const TextStyle(color: Color(0xFF8899AA)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(t['cancel_btn']!),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(
              t['up_rollback']!,
              style: const TextStyle(color: Color(0xFFE53935)),
            ),
          ),
        ],
      ),
    );
    if (ok != true) return;
    // Ручной откат из сервисного меню: техник на месте (проверка покоя, как
    // для команды из облака, здесь не нужна — меню само не принимает оплату).
    final res = await UpdateService.startRollback(notifier);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          res.ok
              ? t['up_rollback_started']!
              : '${t['up_rollback_failed']}: ${res.result}',
        ),
      ),
    );
    await res.afterAck?.call();
    await _loadUpdate();
  }

  Future<void> _toggleAdb(bool want) async {
    final t = _i18n[context.read<AppNotifier>().lang]!;
    if (want) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: const Color(0xFF1A2233),
          title: Text(
            t['up_adb']!,
            style: const TextStyle(color: Colors.white),
          ),
          content: Text(
            t['up_adb_warn']!,
            style: const TextStyle(color: Color(0xFFFFAA00)),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text(t['cancel_btn']!),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text(t['up_adb']!.split(':').first),
            ),
          ],
        ),
      );
      if (ok != true) return;
    }
    final done = await UpdateService.setAdbNetwork(want);
    if (!mounted) return;
    if (!done) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(t['up_adb_failed']!)));
    }
    await _loadUpdate();
  }

  Future<void> _loadCommands() async {
    final list = await CommandGuard.history();
    if (mounted) setState(() => _commands = list);
  }

  Future<void> _sendDiagnostics() async {
    setState(() => _diagBusy = true);
    final notifier = context.read<AppNotifier>();
    try {
      await DiagnosticsService.collectAndSend(
        notifier,
        trigger: 'service_menu',
      );
    } finally {
      if (mounted) setState(() => _diagBusy = false);
    }
  }

  @override
  void initState() {
    super.initState();
    unawaited(_loadCommands());
    unawaited(_loadUpdate());
    final config = context.read<AppNotifier>().config;
    _deviceIdCtrl = TextEditingController(text: config.deviceId);
    _urlCtrl = TextEditingController(text: config.cloudUrl);
    _keyCtrl = TextEditingController(text: config.cloudAnonKey);
    _tokenCtrl = TextEditingController(text: config.cloudToken);
    _enabled = config.cloudEnabled;
  }

  @override
  void dispose() {
    _deviceIdCtrl.dispose();
    _urlCtrl.dispose();
    _keyCtrl.dispose();
    _tokenCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final notifier = context.read<AppNotifier>();
    final t = _i18n[notifier.lang]!;

    final updated = notifier.config.copyWith(
      deviceId: _deviceIdCtrl.text.trim(),
      cloudUrl: _urlCtrl.text.trim(),
      cloudAnonKey: _keyCtrl.text.trim(),
      cloudToken: _tokenCtrl.text.trim(),
      cloudEnabled: _enabled,
    );

    await notifier.saveConfig(updated);

    CloudService.configure(
      deviceId: updated.deviceId,
      enabled: updated.cloudEnabled,
      url: updated.cloudUrl,
      anonKey: updated.cloudAnonKey,
      token: updated.cloudToken,
    );

    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(t['saved']!)));
  }

  Future<void> _test() async {
    setState(() => _testing = true);
    await _save();

    final ok = await CloudService.transport.send(CloudService.deviceId, [
      CloudEvent(type: CloudEventType.appStarted, data: const {'test': true}),
    ]);

    if (!mounted) return;
    final t = _i18n[context.read<AppNotifier>().lang]!;
    setState(() => _testing = false);

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(ok ? t['cloud_ok']! : t['cloud_fail']!),
        backgroundColor: ok ? const Color(0xFF00C6B2) : const Color(0xFFE53935),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final t = _i18n[context.watch<AppNotifier>().lang]!;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  t['cloud_enabled']!,
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                ),
              ),
              Switch(
                value: _enabled,
                onChanged: (v) => setState(() => _enabled = v),
                activeThumbColor: const Color(0xFF00C6B2),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            t['cloud_hint']!,
            style: const TextStyle(color: Color(0xFF8899AA), fontSize: 12),
          ),

          const SizedBox(height: 20),

          _Field(
            label: t['cloud_device_id']!,
            controller: _deviceIdCtrl,
            keyboardType: TextInputType.text,
            inputFormatters: const [],
          ),
          const SizedBox(height: 16),
          _Field(
            label: t['cloud_url']!,
            controller: _urlCtrl,
            keyboardType: TextInputType.url,
            inputFormatters: const [],
          ),
          const SizedBox(height: 16),
          _Field(
            label: t['cloud_key']!,
            controller: _keyCtrl,
            keyboardType: TextInputType.text,
            inputFormatters: const [],
          ),
          const SizedBox(height: 16),
          _Field(
            label: t['cloud_token']!,
            controller: _tokenCtrl,
            keyboardType: TextInputType.text,
            inputFormatters: const [],
            obscure: true,
          ),

          const SizedBox(height: 28),

          Row(
            children: [
              Expanded(
                child: ElevatedButton(
                  onPressed: _testing ? null : _save,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF00C6B2),
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  child: Text(
                    t['save']!,
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton(
                  onPressed: _testing ? null : _test,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFF00C6B2),
                    side: const BorderSide(color: Color(0xFF00C6B2)),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  child: Text(
                    _testing ? t['cloud_testing']! : t['cloud_test']!,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton(
              onPressed: _testing
                  ? null
                  : () async {
                      await SyncService.syncNow();
                      if (!context.mounted) return;
                      final t2 = _i18n[context.read<AppNotifier>().lang]!;
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text(t2['cloud_synced']!)),
                      );
                    },
              style: OutlinedButton.styleFrom(
                foregroundColor: const Color(0xFF8899AA),
                side: const BorderSide(color: Color(0xFF334455)),
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              child: Text(t['cloud_sync_now']!),
            ),
          ),
          const SizedBox(height: 28),
          Container(height: 1, color: const Color(0xFF1A2233)),
          const SizedBox(height: 20),
          Text(
            t['rd_title']!,
            style: const TextStyle(
              color: Color(0xFF00C6B2),
              fontSize: 15,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 10),
          Builder(
            builder: (context) {
              final st = DiagnosticsService.last;
              final line = st == null
                  ? t['rd_none']!
                  : '${st.at.toLocal().toString().split('.').first} · '
                        '${(st.sizeBytes / 1024).toStringAsFixed(1)} КБ · '
                        '${st.parts} ч. · '
                        '${st.sent ? t['rd_sent'] : t['rd_unsent']}'
                        '${st.error != null ? ' (${st.error})' : ''}';
              return Text(
                '${t['rd_last']}: $line',
                style: TextStyle(
                  color: st != null && !st.sent
                      ? const Color(0xFFFFAA00)
                      : const Color(0xFF8899AA),
                  fontSize: 13,
                ),
              );
            },
          ),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton(
              onPressed: _diagBusy ? null : _sendDiagnostics,
              style: OutlinedButton.styleFrom(
                foregroundColor: const Color(0xFF00C6B2),
                side: const BorderSide(color: Color(0xFF00C6B2)),
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              child: Text(_diagBusy ? t['rd_sending']! : t['rd_send']!),
            ),
          ),
          const SizedBox(height: 16),
          Text(
            t['rd_commands']!,
            style: const TextStyle(color: Color(0xFF8899AA), fontSize: 13),
          ),
          const SizedBox(height: 6),
          if (_commands.isEmpty)
            Text(
              t['rd_no_commands']!,
              style: const TextStyle(color: Color(0xFF556677), fontSize: 12),
            )
          else
            for (final c in _commands)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  '${(c['at'] as String).substring(5, 19).replaceAll('T', ' ')} · '
                  '${c['action']} · ${c['ok'] == true ? 'OK' : 'отказ'} · '
                  '${c['result']}',
                  style: TextStyle(
                    color: c['ok'] == true
                        ? const Color(0xFF8899AA)
                        : const Color(0xFFFFAA00),
                    fontSize: 12,
                  ),
                ),
              ),
          const SizedBox(height: 28),
          Container(height: 1, color: const Color(0xFF1A2233)),
          const SizedBox(height: 20),
          Text(
            t['up_title']!,
            style: const TextStyle(
              color: Color(0xFF00C6B2),
              fontSize: 15,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            '${t['up_version']}: ${_upd['version_name'] ?? '—'} (${_upd['version_code'] ?? '—'})',
            style: const TextStyle(color: Colors.white, fontSize: 13),
          ),
          const SizedBox(height: 4),
          Text(
            '${t['up_backup']}: ${_upd['rollback_available'] == true ? '${_upd['backup_name']} (${_upd['backup_code']})' : t['up_backup_none']}',
            style: const TextStyle(color: Color(0xFF8899AA), fontSize: 13),
          ),
          const SizedBox(height: 4),
          Builder(
            builder: (context) {
              final last = _upd['last'] as Map?;
              final line = last == null
                  ? t['up_last_none']!
                  : '${(last['at'] as String).substring(0, 19).replaceAll('T', ' ')} · ${last['result']}'
                        '${last['from'] != null ? ' · ${last['from']} → ${last['to']}' : ''}';
              return Text(
                '${t['up_last']}: $line',
                style: TextStyle(
                  color: last != null && last['ok'] == false
                      ? const Color(0xFFFFAA00)
                      : const Color(0xFF8899AA),
                  fontSize: 13,
                ),
              );
            },
          ),
          const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton(
              onPressed:
                  (_upd['rollback_available'] == true &&
                      !UpdateService.inProgress)
                  ? _rollback
                  : null,
              style: OutlinedButton.styleFrom(
                foregroundColor: const Color(0xFFE53935),
                side: const BorderSide(color: Color(0xFFE53935)),
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              child: Text(t['up_rollback']!),
            ),
          ),
          const SizedBox(height: 20),
          Row(
            children: [
              Expanded(
                child: Text(
                  t['up_adb']!,
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                ),
              ),
              Switch(
                value: _adb == true,
                onChanged: _adb == null ? null : _toggleAdb,
              ),
            ],
          ),
          Text(
            '${t['up_adb_state']}: ${_adb == null ? t['up_adb_unknown'] : (_adb! ? 'ON (5555)' : 'OFF')}',
            style: const TextStyle(color: Color(0xFF8899AA), fontSize: 12),
          ),
        ],
      ),
    );
  }
}

// ============================================================
// ВКЛАДКА: КИОСК-РЕЖИМ (Шаг 32, задача 3)
// ============================================================

class _KioskTab extends StatefulWidget {
  @override
  State<_KioskTab> createState() => _KioskTabState();
}

class _KioskTabState extends State<_KioskTab> {
  late bool _enabled;

  @override
  void initState() {
    super.initState();
    _enabled = context.read<AppNotifier>().config.kioskModeEnabled;
  }

  Future<void> _onToggle(bool value) async {
    setState(() => _enabled = value);

    final notifier = context.read<AppNotifier>();
    await notifier.saveConfig(
      notifier.config.copyWith(kioskModeEnabled: value),
    );
    await SystemService.setKioskHomeEnabled(value);

    if (value) {
      // Экран "Приложение по умолчанию → Домашний экран" — самый надёжный
      // способ сразу предложить выбрать это приложение (проверено вживую
      // дважды). Обычный резолвер "Только сейчас/Всегда" (triggerHomeChooser)
      // оказался не всегда таким же надёжным — в одном из тестов вариант
      // диалога с "Use a different app" не закрепил выбор так же прочно.
      // Поэтому здесь используем экран настроек, а подтверждение "Всегда" в
      // резолвере (если он всплывёт) остаётся на технике при первом нажатии
      // "Домой" после выбора — см. пояснение под кнопкой ниже.
      await SystemService.openHomeSettings();
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = _i18n[context.watch<AppNotifier>().lang]!;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  t['kiosk_enabled']!,
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                ),
              ),
              Switch(
                value: _enabled,
                onChanged: _onToggle,
                activeThumbColor: const Color(0xFF00C6B2),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            t['kiosk_hint']!,
            style: const TextStyle(color: Color(0xFF8899AA), fontSize: 12),
          ),

          const SizedBox(height: 28),
          Container(height: 1, color: const Color(0xFF1A2233)),
          const SizedBox(height: 28),

          SizedBox(
            width: double.infinity,
            child: OutlinedButton(
              onPressed: () => SystemService.openHomeSettings(),
              style: OutlinedButton.styleFrom(
                foregroundColor: const Color(0xFF00C6B2),
                side: const BorderSide(color: Color(0xFF00C6B2)),
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
              child: Text(
                t['kiosk_open_desktop']!,
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            t['kiosk_open_desktop_hint']!,
            style: const TextStyle(color: Color(0xFF8899AA), fontSize: 12),
          ),
        ],
      ),
    );
  }
}
