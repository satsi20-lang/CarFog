# Проверка перевода: Deutsch (de)

* Версия перевода (manifest): 1
* Статус: **draft**
* Дата листа: 2026-10-10
* **Черновик машинного перевода, требуется проверка носителем языка.**
  До проверки язык на боевых аппаратах не показывается.

Заполните столбец «замена» там, где перевод нужно исправить (пусто = верно).
Слова в фигурных скобках ({seconds}, {temp}, {flavor}) не менять.

## Пометки переводчика (сомнительные места)

* `standby.subtitle` — «Trockennebel» — так ли называют услугу сухого тумана для салона на немецком рынке?
* `preparing.hint2` — «Umluft» — проверить, что это понятный термин рециркуляции в авто.
* `treating.warning_sub` — Перевод «Get ready to remove the hose» сокращён до «Bereit zum Entnehmen des Schlauchs».
* `error.heater_failure.detail` — Возврат денег: «Für eine Erstattung wenden Sie sich bitte an das Personal» — без обещания автоматического возврата.

## Критичные (оплата, деньги, авария, инструкции)

| ключ | en | перевод | замена (заполняет носитель) |
|---|---|---|---|
| `payment.title` | PAYMENT | ZAHLUNG |  |
| `payment.flavor` | Fragrance | Duft |  |
| `payment.price` | Service price | Preis der Behandlung |  |
| `payment.paid` | Paid | Bezahlt |  |
| `payment.remaining` | Remaining | Restbetrag |  |
| `payment.instruction` | Insert coins | Münzen einwerfen |  |
| `payment.instruction_with_card` | Insert coins or tap your card | Münzen einwerfen oder Karte auflegen |  |
| `payment.instruction_coin_down_with_card` | Coin payment unavailable — pay by card | Münzzahlung nicht möglich – bitte mit Karte zahlen |  |
| `payment.cancel` | Cancel | Abbrechen |  |
| `preparing.hint1` | 1. Insert the hose through a slightly open window | 1. Führen Sie den Schlauch durch ein leicht geöffnetes Fenster ein |  |
| `preparing.hint2` ⚠ | 2. Turn on cabin air recirculation | 2. Schalten Sie die Umluft im Fahrzeug ein |  |
| `preparing.hint3` | 3. Close all doors and wait outside | 3. Schließen Sie alle Türen und warten Sie draußen |  |
| `preparing.hint4` | 4. After treatment ends, the pump keeps spraying for {seconds} more sec — do not touch the hose | 4. Nach der Behandlung sprüht die Pumpe noch {seconds} Sek. – Schlauch nicht berühren |  |
| `treating.cancel_title` | Stop the procedure? | Vorgang abbrechen? |  |
| `treating.cancel_body` | Payment is not refunded automatically. The procedure will be interrupted. | Die Zahlung wird nicht automatisch erstattet. Der Vorgang wird abgebrochen. |  |
| `treating.cancel_yes` | Stop | Stoppen |  |
| `treating.cancel_no` | Continue | Fortsetzen |  |
| `finished.title` | Treatment complete! | Behandlung abgeschlossen! |  |
| `finished.subtitle` | Your car interior has been treated with dry fog. | Der Innenraum Ihres Fahrzeugs wurde mit Trockennebel behandelt. |  |
| `finished.returning` | Returning to start | Zurück zum Start |  |
| `finished.countdown` | {seconds}s | {seconds} s |  |
| `error.overheat.title` | Overheating | Überhitzung |  |
| `error.overheat.detail` | Temperature exceeded 240°C. All devices have been shut down. | Temperatur über 240°C. Alle Geräte wurden abgeschaltet. |  |
| `error.timeout.title` | Heating timeout | Aufheizzeit überschritten |  |
| `error.timeout.detail` | Device did not reach 225°C within 600 seconds. | Das Gerät hat 225°C nicht innerhalb von 600 Sekunden erreicht. |  |
| `error.sensor.title` | Sensor error | Sensorfehler |  |
| `error.sensor.detail` | Temperature sensor is not responding. | Der Temperatursensor antwortet nicht. |  |
| `error.generic.title` | System error | Systemfehler |  |
| `error.generic.detail` | An unexpected error occurred. | Ein unerwarteter Fehler ist aufgetreten. |  |
| `error.bus_unavailable.title` | Temporarily out of service | Vorübergehend außer Betrieb |  |
| `error.bus_unavailable.detail` | Payments are not being accepted right now. Please try again later. | Zahlungen werden derzeit nicht angenommen. Bitte versuchen Sie es später erneut. |  |
| `error.coin_acceptor_unavailable.title` | Coin payment temporarily unavailable | Münzzahlung vorübergehend nicht möglich |  |
| `error.coin_acceptor_unavailable.detail` | Please use card payment or contact the service staff. | Bitte zahlen Sie mit Karte oder wenden Sie sich an das Personal. |  |
| `error.heater_failure.title` | Device could not start | Gerät konnte nicht starten |  |
| `error.heater_failure.detail` ⚠ | The service was not provided. Please contact the service staff for a refund. | Die Leistung wurde nicht erbracht. Für eine Erstattung wenden Sie sich bitte an das Personal. |  |
| `error.heater_sensor_fault.title` | Device could not start | Gerät konnte nicht starten |  |
| `error.heater_sensor_fault.detail` | The service was not provided. Please contact the service staff for a refund. | Die Leistung wurde nicht erbracht. Für eine Erstattung wenden Sie sich bitte an das Personal. |  |
| `error.contact` | Please contact the service staff. | Bitte wenden Sie sich an das Personal. |  |
| `error.returning` | Returning to start | Zurück zum Start |  |
| `error.countdown` | {seconds}s | {seconds} s |  |
| `out_of_service.title` | Temporarily out of service | Vorübergehend außer Betrieb |  |
| `out_of_service.detail` | Payments are not being accepted. We apologise for the inconvenience. | Zahlungen werden nicht angenommen. Wir bitten um Entschuldigung. |  |

## Остальные

| ключ | en | перевод | замена (заполняет носитель) |
|---|---|---|---|
| `standby.tap_to_start` | Tap to start | Zum Starten tippen |  |
| `standby.subtitle` ⚠ | DRY FOG | TROCKENNEBEL |  |
| `language_select.title` | SELECT LANGUAGE | SPRACHE WÄHLEN |  |
| `select_flavor.title` | CHOOSE A FRAGRANCE | DUFT WÄHLEN |  |
| `select_flavor.hint` | Greyed-out fragrances are temporarily unavailable | Grau dargestellte Düfte sind vorübergehend nicht verfügbar |  |
| `select_flavor.unavailable` | (unavailable) | (nicht verfügbar) |  |
| `select_flavor.cancel` | Cancel | Abbrechen |  |
| `preparing.title` | Preheating... | Vorheizen... |  |
| `preparing.subtitle` | Heating the evaporator, please wait | Der Verdampfer heizt auf, bitte warten |  |
| `preparing.target` | Target {temp}°C | Ziel {temp}°C |  |
| `preparing.cancel` | Cancel | Abbrechen |  |
| `treating.compressor_title` | STARTING COMPRESSOR | KOMPRESSOR STARTET |  |
| `treating.compressor_sub` | Please wait | Bitte warten |  |
| `treating.treating_title` | TREATING VEHICLE INTERIOR | INNENRAUM WIRD BEHANDELT |  |
| `treating.treating_sub` | Fragrance is being sprayed — please wait | Duft wird versprüht – bitte warten |  |
| `treating.warning_title` | SESSION ENDING! | BEHANDLUNG ENDET! |  |
| `treating.warning_sub` ⚠ | Get ready to remove the hose | Bereit zum Entnehmen des Schlauchs |  |
| `treating.shutdown_title` | FINISHING UP | ABSCHLUSS |  |
| `treating.shutdown_sub` | Purging the system, please wait | System wird gespült, bitte warten |  |
| `treating.flavor` | Fragrance: {flavor} | Duft: {flavor} |  |
| `treating.seconds` | {seconds} s | {seconds} s |  |
| `treating.cancel` | Cancel | Abbrechen |  |

## Чек-лист

- [ ] Звучит естественно для экрана самообслуживания (коротко, без канцелярита).
- [ ] Вежливая форма обращения выдержана везде одинаково.
- [ ] Нет двусмысленности в инструкциях про шланг, окно, двери и ожидание снаружи (preparing.hint1–hint4).
- [ ] Фразы про деньги точны: оплата не возвращается автоматически при отмене (treating.cancel_body); при отказе — возврат только через персонал (error.*); ничего не обещано сверх английского текста.
- [ ] Единицы: секунды после {seconds}, «°C» после {temp}; слова в фигурных скобках не изменены.
- [ ] Диакритика и заглавные буквы в заголовках верны.
- [ ] Перевод «dry fog» (standby.subtitle, finished.subtitle) — принятый термин.

Подпись носителя языка, дата: ____________________
