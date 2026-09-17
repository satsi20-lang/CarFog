import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../../models/app_state.dart';
import '../../widgets/lang_switcher.dart';
import '../../services/cloud_service.dart';
import '../../services/modbus_service.dart';
import '../../services/sync_service.dart';
import '../../services/system_service.dart';

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
    'compressor_purge_label':
        'Продувка компрессора до включения насосов и ТЭНа (сек)',
    'pump_after_heater_label': 'Работа насоса после выключения ТЭНа (сек)',
    'err_compressor_purge': 'Продувка компрессора: 1–30 сек',
    'err_pump_after_heater': 'Работа насоса после ТЭНа: 1–30 сек',
    'available': 'Есть',
    'empty_level': 'Пусто',
    'flavor_fallback': 'Аромат',
    'coin_label': 'Монета',
    'coin_yes': 'ДА',
    'coin_no': 'НЕТ',
    'temp_label': 'Температура',
    'temp_unavailable': '--',
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
    'unit_kwh': 'кВт⋅ч',
    'tab_cloud': 'Облако',
    'cloud_enabled': 'Отправлять данные в облако',
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
    'scanner_clear': 'Очистить результаты',
    // --- Починка обмена по шине (задача "починить обмен по шине") ---
    'bus_healthy': 'Шина работает',
    'bus_unhealthy': 'Шина недоступна',
    'watchdog_enabled': 'Сторож выходов (диагностический режим)',
    'watchdog_hint':
        'Периодически сверяет фактическое состояние выходов с ожидаемым '
        '"всё выключено" в покое. Выключен по умолчанию — включайте, только '
        'когда обмен по шине подтверждённо исправен.',
    'scanner_sweep_hint':
        'Устройство не отвечает ни на одном адресе на текущей скорости? '
        'Проверьте другие скорости — порт вернётся на рабочую скорость '
        'после проверки в любом случае.',
    'scanner_sweep_btn': 'Перебрать скорость (4800/19200/38400/115200)',
    'scanner_sweep_found': 'Найден на скорости',
    'scanner_sweep_not_found': 'Не найден ни на одной скорости',
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
    'compressor_purge_label':
        'Compressor purge before pumps/heater turn on (sec)',
    'pump_after_heater_label': 'Pump run time after heater turns off (sec)',
    'err_compressor_purge': 'Compressor purge: 1–30 sec',
    'err_pump_after_heater': 'Pump after heater: 1–30 sec',
    'available': 'OK',
    'empty_level': 'Empty',
    'flavor_fallback': 'Fragrance',
    'coin_label': 'Coin',
    'coin_yes': 'YES',
    'coin_no': 'NO',
    'temp_label': 'Temperature',
    'temp_unavailable': '--',
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
    'unit_kwh': 'kWh',
    'tab_cloud': 'Cloud',
    'cloud_enabled': 'Send data to the cloud',
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
    'scanner_clear': 'Clear results',
    // --- Bus exchange fix ---
    'bus_healthy': 'Bus is working',
    'bus_unhealthy': 'Bus unavailable',
    'watchdog_enabled': 'Output watchdog (diagnostic mode)',
    'watchdog_hint':
        'Periodically checks that outputs are actually off while idle, as '
        'expected. Off by default — enable only once bus exchange is '
        'confirmed healthy.',
    'scanner_sweep_hint':
        'Device not answering on any address at the current baud rate? '
        'Try other baud rates — the port returns to the working rate '
        'after the check either way.',
    'scanner_sweep_btn': 'Sweep baud rate (4800/19200/38400/115200)',
    'scanner_sweep_found': 'Found at baud',
    'scanner_sweep_not_found': 'Not found at any baud rate',
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
    'compressor_purge_label':
        'Kompressori puhastus enne pumpade/küttekeha sisselülitamist (sek)',
    'pump_after_heater_label':
        'Pumba töö pärast küttekeha väljalülitamist (sek)',
    'err_compressor_purge': 'Kompressori puhastus: 1–30 sek',
    'err_pump_after_heater': 'Pump pärast küttekeha: 1–30 sek',
    'available': 'Olemas',
    'empty_level': 'Tühi',
    'coin_label': 'Münt',
    'coin_yes': 'JAH',
    'coin_no': 'EI',
    'temp_label': 'Temperatuur',
    'temp_unavailable': '--',
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
    'unit_kwh': 'kWh',
    'tab_cloud': 'Pilv',
    'cloud_enabled': 'Saada andmed pilve',
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
    'scanner_clear': 'Tühjenda tulemused',
    // --- Siiniühenduse parandus ---
    'bus_healthy': 'Siin töötab',
    'bus_unhealthy': 'Siin pole saadaval',
    'watchdog_enabled': 'Väljundite valvur (diagnostikarežiim)',
    'watchdog_hint':
        'Kontrollib perioodiliselt, kas väljundid on tegelikult välja '
        'lülitatud, kui peaks. Vaikimisi väljas — lülita sisse alles siis, '
        'kui siiniühendus on kinnitatult korras.',
    'scanner_sweep_hint':
        'Seade ei vasta ühelegi aadressile praegusel kiirusel? Proovi '
        'teisi kiirusi — port taastub töökiirusele igal juhul pärast '
        'kontrolli.',
    'scanner_sweep_btn': 'Proovi kiirusi (4800/19200/38400/115200)',
    'scanner_sweep_found': 'Leitud kiirusel',
    'scanner_sweep_not_found': 'Ei leitud ühelgi kiirusel',
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
        return const _DiagnosticsTab();
      case 3:
        return const _SensorsTab();
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

  @override
  void initState() {
    super.initState();
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
    if (compressorPurge == null ||
        compressorPurge < 1 ||
        compressorPurge > 30) {
      _snack(t['err_compressor_purge']!);
      return;
    }
    if (pumpAfterHeater == null ||
        pumpAfterHeater < 1 ||
        pumpAfterHeater > 30) {
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

  double? _temperature;
  Timer? _tempTimer;

  late bool _watchdogEnabled;

  @override
  void initState() {
    super.initState();
    _watchdogEnabled = context.read<AppNotifier>().config.outputWatchdogEnabled;
    _readEnergy();
    _energyTimer = Timer.periodic(
      const Duration(seconds: 3),
      (_) => _readEnergy(),
    );
    _coinTimer = Timer.periodic(
      const Duration(milliseconds: 500),
      (_) => _readCoin(),
    );
    _readTemperature();
    _tempTimer = Timer.periodic(
      const Duration(seconds: 2),
      (_) => _readTemperature(),
    );
  }

  @override
  void dispose() {
    _energyTimer?.cancel();
    _coinTimer?.cancel();
    _tempTimer?.cancel();
    super.dispose();
  }

  Future<void> _readCoin() async {
    final detected = await ModbusService.readCoin();
    if (mounted) setState(() => _coinDetected = detected);
  }

  Future<void> _readTemperature() async {
    final temp = await ModbusService.readTemperature(channel: 0);
    if (mounted) setState(() => _temperature = temp);
  }

  Future<void> _readEnergy() async {
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

  @override
  Widget build(BuildContext context) {
    final notifier = context.watch<AppNotifier>();
    final lang = notifier.lang;
    final t = _i18n[lang]!;
    final levels = notifier.levels;
    final flavors = notifier.config.flavorNames[lang] ?? [];
    final busHealthy = notifier.busHealthy;

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
          child: Row(
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
        ),
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
        const SizedBox(height: 10),
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
                _temperature != null
                    ? '${_temperature!.toStringAsFixed(1)} °C'
                    : t['temp_unavailable']!,
                style: TextStyle(
                  color: _temperature != null
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
              return _ToggleRow(
                label: label,
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
                onPressed: _busy ? null : _allOff,
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
      final channel = int.tryParse(_terminalChannelCtrl.text) ?? 10;
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
    if (channel == null || channel < 0 || channel > 15) {
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
  static int readFunc = 0x03;
  static int readStartAddr = 0;
  static int readCount = 1;
  static int writeSlave = 1;
  static String writeType = 'register'; // 'register' | 'coil'
  static int writeAddr = 0;
  static int writeValue = 0;
}

// Известные по конфигурации проекта адреса (ModbusChannel.kt: SLAVE_DIO,
// SLAVE_THERMO, SLAVE_ENERGY) — подписываются в результатах поиска, если
// совпали. Дублирование намеренное: у Dart нет доступа к константам
// нативной стороны, значения нужно держать в синхроне вручную при их
// изменении там.
const Map<int, String> _knownSlaves = {
  1: 'scanner_known_thermo',
  3: 'scanner_known_energy',
  5: 'scanner_known_dio',
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
  final List<int> _scanFound = [];

  // --- Перебор скорости (диагностика "молчащий, но подключённый адрес")
  late TextEditingController _sweepSlaveCtrl;
  bool _sweeping = false;
  String? _sweepResultText;
  bool? _sweepOk;

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

  @override
  void initState() {
    super.initState();
    _scanFromCtrl = TextEditingController(text: '${_ScannerParams.scanFrom}');
    _scanToCtrl = TextEditingController(text: '${_ScannerParams.scanTo}');
    _sweepSlaveCtrl = TextEditingController(text: '5');
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
    _readSlaveCtrl.dispose();
    _readStartCtrl.dispose();
    _readCountCtrl.dispose();
    _writeSlaveCtrl.dispose();
    _writeAddrCtrl.dispose();
    _writeValueCtrl.dispose();
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
  };

  static const _alarmTypes = {
    'unauthorized_access',
    'master_code_used',
    'factory_reset',
    'hardware_error',
    'app_started_after_crash',
    'unexpected_payment',
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

  @override
  void initState() {
    super.initState();
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
