# Проверка перевода: Svenska (sv)

* Версия перевода (manifest): 1
* Статус: **draft**
* Дата листа: 2026-10-10
* **Черновик машинного перевода, требуется проверка носителем языка.**
  До проверки язык на боевых аппаратах не показывается.

Заполните столбец «замена» там, где перевод нужно исправить (пусто = верно).
Слова в фигурных скобках ({seconds}, {temp}, {flavor}) не менять.

## Пометки переводчика (сомнительные места)

* `standby.subtitle` — «Torrdimma» — термин услуги?
* `treating.shutdown_sub` — «Systemet blåses rent» — продувка системы.
* `payment.instruction_with_card` — «håll fram kortet» — естественно ли для бесконтактной оплаты (часто «blippa»)?

## Критичные (оплата, деньги, авария, инструкции)

| ключ | en | перевод | замена (заполняет носитель) |
|---|---|---|---|
| `payment.title` | PAYMENT | BETALNING |  |
| `payment.flavor` | Fragrance | Doft |  |
| `payment.price` | Service price | Pris för tjänsten |  |
| `payment.paid` | Paid | Betalt |  |
| `payment.remaining` | Remaining | Kvar att betala |  |
| `payment.instruction` | Insert coins | Sätt i mynt |  |
| `payment.instruction_with_card` ⚠ | Insert coins or tap your card | Sätt i mynt eller håll fram kortet |  |
| `payment.instruction_coin_down_with_card` | Coin payment unavailable — pay by card | Myntbetalning ej möjlig — betala med kort |  |
| `payment.cancel` | Cancel | Avbryt |  |
| `preparing.hint1` | 1. Insert the hose through a slightly open window | 1. Stick in slangen genom ett lätt öppet fönster |  |
| `preparing.hint2` | 2. Turn on cabin air recirculation | 2. Slå på kupéns luftåtercirkulation |  |
| `preparing.hint3` | 3. Close all doors and wait outside | 3. Stäng alla dörrar och vänta utanför |  |
| `preparing.hint4` | 4. After treatment ends, the pump keeps spraying for {seconds} more sec — do not touch the hose | 4. Efter behandlingen sprutar pumpen i {seconds} s till — rör inte slangen |  |
| `treating.cancel_title` | Stop the procedure? | Avbryta behandlingen? |  |
| `treating.cancel_body` | Payment is not refunded automatically. The procedure will be interrupted. | Betalningen återbetalas inte automatiskt. Behandlingen avbryts. |  |
| `treating.cancel_yes` | Stop | Stoppa |  |
| `treating.cancel_no` | Continue | Fortsätt |  |
| `finished.title` | Treatment complete! | Behandlingen är klar! |  |
| `finished.subtitle` | Your car interior has been treated with dry fog. | Bilens kupé har behandlats med torrdimma. |  |
| `finished.returning` | Returning to start | Återgår till start |  |
| `finished.countdown` | {seconds}s | {seconds} s |  |
| `error.overheat.title` | Overheating | Överhettning |  |
| `error.overheat.detail` | Temperature exceeded 240°C. All devices have been shut down. | Temperaturen översteg 240°C. All utrustning har stängts av. |  |
| `error.timeout.title` | Heating timeout | För lång uppvärmning |  |
| `error.timeout.detail` | Device did not reach 225°C within 600 seconds. | Enheten nådde inte 225°C inom 600 sekunder. |  |
| `error.sensor.title` | Sensor error | Sensorfel |  |
| `error.sensor.detail` | Temperature sensor is not responding. | Temperatursensorn svarar inte. |  |
| `error.generic.title` | System error | Systemfel |  |
| `error.generic.detail` | An unexpected error occurred. | Ett oväntat fel inträffade. |  |
| `error.bus_unavailable.title` | Temporarily out of service | Tillfälligt ur funktion |  |
| `error.bus_unavailable.detail` | Payments are not being accepted right now. Please try again later. | Betalningar tas inte emot just nu. Försök igen senare. |  |
| `error.coin_acceptor_unavailable.title` | Coin payment temporarily unavailable | Myntbetalning tillfälligt otillgänglig |  |
| `error.coin_acceptor_unavailable.detail` | Please use card payment or contact the service staff. | Betala med kort eller kontakta personalen. |  |
| `error.heater_failure.title` | Device could not start | Enheten kunde inte starta |  |
| `error.heater_failure.detail` | The service was not provided. Please contact the service staff for a refund. | Tjänsten utfördes inte. Kontakta personalen för återbetalning. |  |
| `error.heater_sensor_fault.title` | Device could not start | Enheten kunde inte starta |  |
| `error.heater_sensor_fault.detail` | The service was not provided. Please contact the service staff for a refund. | Tjänsten utfördes inte. Kontakta personalen för återbetalning. |  |
| `error.contact` | Please contact the service staff. | Kontakta personalen. |  |
| `error.returning` | Returning to start | Återgår till start |  |
| `error.countdown` | {seconds}s | {seconds} s |  |
| `out_of_service.title` | Temporarily out of service | Tillfälligt ur funktion |  |
| `out_of_service.detail` | Payments are not being accepted. We apologise for the inconvenience. | Betalningar tas inte emot. Vi ber om ursäkt för besväret. |  |

## Остальные

| ключ | en | перевод | замена (заполняет носитель) |
|---|---|---|---|
| `standby.tap_to_start` | Tap to start | Tryck för att börja |  |
| `standby.subtitle` ⚠ | DRY FOG | TORRDIMMA |  |
| `language_select.title` | SELECT LANGUAGE | VÄLJ SPRÅK |  |
| `select_flavor.title` | CHOOSE A FRAGRANCE | VÄLJ DOFT |  |
| `select_flavor.hint` | Greyed-out fragrances are temporarily unavailable | Gråmarkerade dofter är tillfälligt otillgängliga |  |
| `select_flavor.unavailable` | (unavailable) | (ej tillgänglig) |  |
| `select_flavor.cancel` | Cancel | Avbryt |  |
| `preparing.title` | Preheating... | Förvärmning... |  |
| `preparing.subtitle` | Heating the evaporator, please wait | Förångaren värms upp, vänta |  |
| `preparing.target` | Target {temp}°C | Mål {temp}°C |  |
| `preparing.cancel` | Cancel | Avbryt |  |
| `treating.compressor_title` | STARTING COMPRESSOR | KOMPRESSORN STARTAR |  |
| `treating.compressor_sub` | Please wait | Vänta |  |
| `treating.treating_title` | TREATING VEHICLE INTERIOR | KUPÉN BEHANDLAS |  |
| `treating.treating_sub` | Fragrance is being sprayed — please wait | Doften sprutas ut — vänta |  |
| `treating.warning_title` | SESSION ENDING! | BEHANDLINGEN SLUTAR! |  |
| `treating.warning_sub` | Get ready to remove the hose | Förbered dig på att ta ut slangen |  |
| `treating.shutdown_title` | FINISHING UP | AVSLUTAR |  |
| `treating.shutdown_sub` ⚠ | Purging the system, please wait | Systemet blåses rent, vänta |  |
| `treating.flavor` | Fragrance: {flavor} | Doft: {flavor} |  |
| `treating.seconds` | {seconds} s | {seconds} s |  |
| `treating.cancel` | Cancel | Avbryt |  |

## Чек-лист

- [ ] Звучит естественно для экрана самообслуживания (коротко, без канцелярита).
- [ ] Вежливая форма обращения выдержана везде одинаково.
- [ ] Нет двусмысленности в инструкциях про шланг, окно, двери и ожидание снаружи (preparing.hint1–hint4).
- [ ] Фразы про деньги точны: оплата не возвращается автоматически при отмене (treating.cancel_body); при отказе — возврат только через персонал (error.*); ничего не обещано сверх английского текста.
- [ ] Единицы: секунды после {seconds}, «°C» после {temp}; слова в фигурных скобках не изменены.
- [ ] Диакритика и заглавные буквы в заголовках верны.
- [ ] Перевод «dry fog» (standby.subtitle, finished.subtitle) — принятый термин.

Подпись носителя языка, дата: ____________________
