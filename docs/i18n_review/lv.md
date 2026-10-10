# Проверка перевода: Latviešu (lv)

* Версия перевода (manifest): 1
* Статус: **draft**
* Дата листа: 2026-10-10
* **Черновик машинного перевода, требуется проверка носителем языка.**
  До проверки язык на боевых аппаратах не показывается.

Заполните столбец «замена» там, где перевод нужно исправить (пусто = верно).
Слова в фигурных скобках ({seconds}, {temp}, {flavor}) не менять.

## Пометки переводчика (сомнительные места)

* `standby.subtitle` — «Sausā migla» — термин услуги?
* `standby.tap_to_start` — Длиннее en в 2 раза; макет проверен.
* `payment.paid` — «Iemaksāts» (внесено) — длиннее en в 2,25 раза; макет проверен.
* `treating.cancel_yes` — «Pārtraukt» — длиннее en в 2,25 раза; макет проверен.
* `error.heater_failure.detail` — Возврат: «Par naudas atmaksu vērsieties pie personāla».

## Критичные (оплата, деньги, авария, инструкции)

| ключ | en | перевод | замена (заполняет носитель) |
|---|---|---|---|
| `payment.title` | PAYMENT | MAKSĀJUMS |  |
| `payment.flavor` | Fragrance | Aromāts |  |
| `payment.price` | Service price | Pakalpojuma cena |  |
| `payment.paid` ⚠ | Paid | Iemaksāts |  |
| `payment.remaining` | Remaining | Atlikums |  |
| `payment.instruction` | Insert coins | Ievietojiet monētas |  |
| `payment.instruction_with_card` | Insert coins or tap your card | Ievietojiet monētas vai pielieciet karti |  |
| `payment.instruction_coin_down_with_card` | Coin payment unavailable — pay by card | Monētas netiek pieņemtas — maksājiet ar karti |  |
| `payment.cancel` | Cancel | Atcelt |  |
| `preparing.hint1` | 1. Insert the hose through a slightly open window | 1. Ievietojiet šļūteni nedaudz atvērtā auto logā |  |
| `preparing.hint2` | 2. Turn on cabin air recirculation | 2. Ieslēdziet salona gaisa recirkulāciju |  |
| `preparing.hint3` | 3. Close all doors and wait outside | 3. Aizveriet visas durvis un gaidiet ārpusē |  |
| `preparing.hint4` | 4. After treatment ends, the pump keeps spraying for {seconds} more sec — do not touch the hose | 4. Pēc apstrādes sūknis vēl {seconds} s smidzina — nepieskarieties šļūtenei |  |
| `treating.cancel_title` | Stop the procedure? | Pārtraukt procedūru? |  |
| `treating.cancel_body` | Payment is not refunded automatically. The procedure will be interrupted. | Maksājums netiek atmaksāts automātiski. Procedūra tiks pārtraukta. |  |
| `treating.cancel_yes` ⚠ | Stop | Pārtraukt |  |
| `treating.cancel_no` | Continue | Turpināt |  |
| `finished.title` | Treatment complete! | Apstrāde pabeigta! |  |
| `finished.subtitle` | Your car interior has been treated with dry fog. | Jūsu automašīnas salons ir apstrādāts ar sauso miglu. |  |
| `finished.returning` | Returning to start | Atgriešanās sākumā |  |
| `finished.countdown` | {seconds}s | {seconds} s |  |
| `error.overheat.title` | Overheating | Pārkaršana |  |
| `error.overheat.detail` | Temperature exceeded 240°C. All devices have been shut down. | Temperatūra pārsniedza 240°C. Visas ierīces ir izslēgtas. |  |
| `error.timeout.title` | Heating timeout | Uzsilšana pārāk ilga |  |
| `error.timeout.detail` | Device did not reach 225°C within 600 seconds. | Ierīce 600 sekundēs nesasniedza 225°C. |  |
| `error.sensor.title` | Sensor error | Sensora kļūda |  |
| `error.sensor.detail` | Temperature sensor is not responding. | Temperatūras sensors neatbild. |  |
| `error.generic.title` | System error | Sistēmas kļūda |  |
| `error.generic.detail` | An unexpected error occurred. | Radās neparedzēta kļūda. |  |
| `error.bus_unavailable.title` | Temporarily out of service | Īslaicīgi nedarbojas |  |
| `error.bus_unavailable.detail` | Payments are not being accepted right now. Please try again later. | Maksājumi pašlaik netiek pieņemti. Lūdzu, mēģiniet vēlāk. |  |
| `error.coin_acceptor_unavailable.title` | Coin payment temporarily unavailable | Monētas īslaicīgi netiek pieņemtas |  |
| `error.coin_acceptor_unavailable.detail` | Please use card payment or contact the service staff. | Lūdzu, maksājiet ar karti vai vērsieties pie personāla. |  |
| `error.heater_failure.title` | Device could not start | Ierīci neizdevās palaist |  |
| `error.heater_failure.detail` ⚠ | The service was not provided. Please contact the service staff for a refund. | Pakalpojums netika sniegts. Par naudas atmaksu vērsieties pie personāla. |  |
| `error.heater_sensor_fault.title` | Device could not start | Ierīci neizdevās palaist |  |
| `error.heater_sensor_fault.detail` | The service was not provided. Please contact the service staff for a refund. | Pakalpojums netika sniegts. Par naudas atmaksu vērsieties pie personāla. |  |
| `error.contact` | Please contact the service staff. | Lūdzu, vērsieties pie personāla. |  |
| `error.returning` | Returning to start | Atgriešanās sākumā |  |
| `error.countdown` | {seconds}s | {seconds} s |  |
| `out_of_service.title` | Temporarily out of service | Īslaicīgi nedarbojas |  |
| `out_of_service.detail` | Payments are not being accepted. We apologise for the inconvenience. | Maksājumi netiek pieņemti. Atvainojamies par neērtībām. |  |

## Остальные

| ключ | en | перевод | замена (заполняет носитель) |
|---|---|---|---|
| `standby.tap_to_start` ⚠ | Tap to start | Pieskarieties, lai sāktu |  |
| `standby.subtitle` ⚠ | DRY FOG | SAUSĀ MIGLA |  |
| `language_select.title` | SELECT LANGUAGE | IZVĒLIETIES VALODU |  |
| `select_flavor.title` | CHOOSE A FRAGRANCE | IZVĒLIETIES AROMĀTU |  |
| `select_flavor.hint` | Greyed-out fragrances are temporarily unavailable | Pelēkie aromāti īslaicīgi nav pieejami |  |
| `select_flavor.unavailable` | (unavailable) | (nav pieejams) |  |
| `select_flavor.cancel` | Cancel | Atcelt |  |
| `preparing.title` | Preheating... | Uzsilšana... |  |
| `preparing.subtitle` | Heating the evaporator, please wait | Iztvaicētājs uzsilst, lūdzu, uzgaidiet |  |
| `preparing.target` | Target {temp}°C | Mērķis {temp}°C |  |
| `preparing.cancel` | Cancel | Atcelt |  |
| `treating.compressor_title` | STARTING COMPRESSOR | KOMPRESORA IESLĒGŠANA |  |
| `treating.compressor_sub` | Please wait | Lūdzu, uzgaidiet |  |
| `treating.treating_title` | TREATING VEHICLE INTERIOR | NOTIEK SALONA APSTRĀDE |  |
| `treating.treating_sub` | Fragrance is being sprayed — please wait | Notiek aromāta smidzināšana — uzgaidiet |  |
| `treating.warning_title` | SESSION ENDING! | SEANSS BEIDZAS! |  |
| `treating.warning_sub` | Get ready to remove the hose | Gatavojieties izņemt šļūteni |  |
| `treating.shutdown_title` | FINISHING UP | PABEIGŠANA |  |
| `treating.shutdown_sub` | Purging the system, please wait | Sistēmas izpūšana, lūdzu, uzgaidiet |  |
| `treating.flavor` | Fragrance: {flavor} | Aromāts: {flavor} |  |
| `treating.seconds` | {seconds} s | {seconds} s |  |
| `treating.cancel` | Cancel | Atcelt |  |

## Чек-лист

- [ ] Звучит естественно для экрана самообслуживания (коротко, без канцелярита).
- [ ] Вежливая форма обращения выдержана везде одинаково.
- [ ] Нет двусмысленности в инструкциях про шланг, окно, двери и ожидание снаружи (preparing.hint1–hint4).
- [ ] Фразы про деньги точны: оплата не возвращается автоматически при отмене (treating.cancel_body); при отказе — возврат только через персонал (error.*); ничего не обещано сверх английского текста.
- [ ] Единицы: секунды после {seconds}, «°C» после {temp}; слова в фигурных скобках не изменены.
- [ ] Диакритика и заглавные буквы в заголовках верны.
- [ ] Перевод «dry fog» (standby.subtitle, finished.subtitle) — принятый термин.

Подпись носителя языка, дата: ____________________
