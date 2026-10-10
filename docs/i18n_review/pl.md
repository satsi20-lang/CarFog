# Проверка перевода: Polski (pl)

* Версия перевода (manifest): 1
* Статус: **draft**
* Дата листа: 2026-10-10
* **Черновик машинного перевода, требуется проверка носителем языка.**
  До проверки язык на боевых аппаратах не показывается.

Заполните столбец «замена» там, где перевод нужно исправить (пусто = верно).
Слова в фигурных скобках ({seconds}, {temp}, {flavor}) не менять.

## Пометки переводчика (сомнительные места)

* `standby.subtitle` — «Sucha mgła» — термин услуги.
* `standby.tap_to_start` — Тон: инфинитивы («Dotknąć», «Wrzucić», «Włożyć») вместо формы на «ты»; проверить, естественно ли для автомата.
* `treating.treating_title` — «TRWA ZABIEG WNĘTRZA AUTA» — подходящее ли слово «zabieg».
* `treating.cancel_yes` — «Przerwać» длиннее en в 2 раза (en «Stop»); макет проверен.
* `error.heater_failure.detail` — Возврат: «W sprawie zwrotu prosimy zwrócić się do obsługi».

## Критичные (оплата, деньги, авария, инструкции)

| ключ | en | перевод | замена (заполняет носитель) |
|---|---|---|---|
| `payment.title` | PAYMENT | PŁATNOŚĆ |  |
| `payment.flavor` | Fragrance | Zapach |  |
| `payment.price` | Service price | Cena usługi |  |
| `payment.paid` | Paid | Wpłata |  |
| `payment.remaining` | Remaining | Pozostało |  |
| `payment.instruction` | Insert coins | Wrzucić monety |  |
| `payment.instruction_with_card` | Insert coins or tap your card | Wrzucić monety lub przyłożyć kartę |  |
| `payment.instruction_coin_down_with_card` | Coin payment unavailable — pay by card | Monety nieobsługiwane — prosimy płacić kartą |  |
| `payment.cancel` | Cancel | Anuluj |  |
| `preparing.hint1` | 1. Insert the hose through a slightly open window | 1. Włożyć wąż przez lekko uchyloną szybę |  |
| `preparing.hint2` | 2. Turn on cabin air recirculation | 2. Włączyć wewnętrzny obieg powietrza |  |
| `preparing.hint3` | 3. Close all doors and wait outside | 3. Zamknąć wszystkie drzwi i czekać na zewnątrz |  |
| `preparing.hint4` | 4. After treatment ends, the pump keeps spraying for {seconds} more sec — do not touch the hose | 4. Po zabiegu pompa rozpyla jeszcze przez {seconds} s — nie dotykać węża |  |
| `treating.cancel_title` | Stop the procedure? | Przerwać zabieg? |  |
| `treating.cancel_body` | Payment is not refunded automatically. The procedure will be interrupted. | Płatność nie jest zwracana automatycznie. Zabieg zostanie przerwany. |  |
| `treating.cancel_yes` ⚠ | Stop | Przerwać |  |
| `treating.cancel_no` | Continue | Kontynuować |  |
| `finished.title` | Treatment complete! | Zabieg zakończony! |  |
| `finished.subtitle` | Your car interior has been treated with dry fog. | Wnętrze samochodu zostało poddane działaniu suchej mgły. |  |
| `finished.returning` | Returning to start | Powrót do początku |  |
| `finished.countdown` | {seconds}s | {seconds} s |  |
| `error.overheat.title` | Overheating | Przegrzanie |  |
| `error.overheat.detail` | Temperature exceeded 240°C. All devices have been shut down. | Temperatura przekroczyła 240°C. Wszystkie urządzenia zostały wyłączone. |  |
| `error.timeout.title` | Heating timeout | Zbyt długie nagrzewanie |  |
| `error.timeout.detail` | Device did not reach 225°C within 600 seconds. | Urządzenie nie osiągnęło 225°C w ciągu 600 sekund. |  |
| `error.sensor.title` | Sensor error | Błąd czujnika |  |
| `error.sensor.detail` | Temperature sensor is not responding. | Czujnik temperatury nie odpowiada. |  |
| `error.generic.title` | System error | Błąd systemu |  |
| `error.generic.detail` | An unexpected error occurred. | Wystąpił nieoczekiwany błąd. |  |
| `error.bus_unavailable.title` | Temporarily out of service | Chwilowo nieczynne |  |
| `error.bus_unavailable.detail` | Payments are not being accepted right now. Please try again later. | Płatności nie są teraz przyjmowane. Prosimy spróbować później. |  |
| `error.coin_acceptor_unavailable.title` | Coin payment temporarily unavailable | Płatność monetami chwilowo niedostępna |  |
| `error.coin_acceptor_unavailable.detail` | Please use card payment or contact the service staff. | Prosimy zapłacić kartą lub zwrócić się do obsługi. |  |
| `error.heater_failure.title` | Device could not start | Urządzenie nie uruchomiło się |  |
| `error.heater_failure.detail` ⚠ | The service was not provided. Please contact the service staff for a refund. | Usługa nie została wykonana. W sprawie zwrotu prosimy zwrócić się do obsługi. |  |
| `error.heater_sensor_fault.title` | Device could not start | Urządzenie nie uruchomiło się |  |
| `error.heater_sensor_fault.detail` | The service was not provided. Please contact the service staff for a refund. | Usługa nie została wykonana. W sprawie zwrotu prosimy zwrócić się do obsługi. |  |
| `error.contact` | Please contact the service staff. | Prosimy zwrócić się do obsługi. |  |
| `error.returning` | Returning to start | Powrót do początku |  |
| `error.countdown` | {seconds}s | {seconds} s |  |
| `out_of_service.title` | Temporarily out of service | Chwilowo nieczynne |  |
| `out_of_service.detail` | Payments are not being accepted. We apologise for the inconvenience. | Płatności nie są przyjmowane. Przepraszamy za utrudnienia. |  |

## Остальные

| ключ | en | перевод | замена (заполняет носитель) |
|---|---|---|---|
| `standby.tap_to_start` ⚠ | Tap to start | Dotknąć, aby zacząć |  |
| `standby.subtitle` ⚠ | DRY FOG | SUCHA MGŁA |  |
| `language_select.title` | SELECT LANGUAGE | WYBÓR JĘZYKA |  |
| `select_flavor.title` | CHOOSE A FRAGRANCE | WYBÓR ZAPACHU |  |
| `select_flavor.hint` | Greyed-out fragrances are temporarily unavailable | Szare zapachy są chwilowo niedostępne |  |
| `select_flavor.unavailable` | (unavailable) | (niedostępny) |  |
| `select_flavor.cancel` | Cancel | Anuluj |  |
| `preparing.title` | Preheating... | Podgrzewanie... |  |
| `preparing.subtitle` | Heating the evaporator, please wait | Nagrzewanie parownika, prosimy czekać |  |
| `preparing.target` | Target {temp}°C | Cel {temp}°C |  |
| `preparing.cancel` | Cancel | Anuluj |  |
| `treating.compressor_title` | STARTING COMPRESSOR | URUCHAMIANIE SPRĘŻARKI |  |
| `treating.compressor_sub` | Please wait | Prosimy czekać |  |
| `treating.treating_title` ⚠ | TREATING VEHICLE INTERIOR | TRWA ZABIEG WNĘTRZA AUTA |  |
| `treating.treating_sub` | Fragrance is being sprayed — please wait | Rozpylanie zapachu — prosimy czekać |  |
| `treating.warning_title` | SESSION ENDING! | ZABIEG DOBIEGA KOŃCA! |  |
| `treating.warning_sub` | Get ready to remove the hose | Prosimy przygotować się do wyjęcia węża |  |
| `treating.shutdown_title` | FINISHING UP | ZAKOŃCZENIE |  |
| `treating.shutdown_sub` | Purging the system, please wait | Przedmuchiwanie układu, prosimy czekać |  |
| `treating.flavor` | Fragrance: {flavor} | Zapach: {flavor} |  |
| `treating.seconds` | {seconds} s | {seconds} s |  |
| `treating.cancel` | Cancel | Anuluj |  |

## Чек-лист

- [ ] Звучит естественно для экрана самообслуживания (коротко, без канцелярита).
- [ ] Вежливая форма обращения выдержана везде одинаково.
- [ ] Нет двусмысленности в инструкциях про шланг, окно, двери и ожидание снаружи (preparing.hint1–hint4).
- [ ] Фразы про деньги точны: оплата не возвращается автоматически при отмене (treating.cancel_body); при отказе — возврат только через персонал (error.*); ничего не обещано сверх английского текста.
- [ ] Единицы: секунды после {seconds}, «°C» после {temp}; слова в фигурных скобках не изменены.
- [ ] Диакритика и заглавные буквы в заголовках верны.
- [ ] Перевод «dry fog» (standby.subtitle, finished.subtitle) — принятый термин.

Подпись носителя языка, дата: ____________________
