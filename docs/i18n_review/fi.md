# Проверка перевода: Suomi (fi)

* Версия перевода (manifest): 1
* Статус: **draft**
* Дата листа: 2026-10-10
* **Черновик машинного перевода, требуется проверка носителем языка.**
  До проверки язык на боевых аппаратах не показывается.

Заполните столбец «замена» там, где перевод нужно исправить (пусто = верно).
Слова в фигурных скобках ({seconds}, {temp}, {flavor}) не менять.

## Пометки переводчика (сомнительные места)

* `standby.subtitle` — «Kuiva sumu» — есть ли устоявшийся термин (kuivasumu?)
* `payment.paid` — «Maksettu» длиннее en в 2 раза (en — 4 символа); макет проверен.
* `treating.cancel_yes` — «Lopeta» вместо «Keskeytä» — ради длины; естественно ли для кнопки остановки?
* `error.heater_failure.detail` — «Saat rahat takaisin henkilökunnalta» — не звучит ли как обещание возврата сверх en?
* `error.timeout.detail` — «225°C:n» — падежное окончание после числа.

## Критичные (оплата, деньги, авария, инструкции)

| ключ | en | перевод | замена (заполняет носитель) |
|---|---|---|---|
| `payment.title` | PAYMENT | MAKSU |  |
| `payment.flavor` | Fragrance | Tuoksu |  |
| `payment.price` | Service price | Palvelun hinta |  |
| `payment.paid` ⚠ | Paid | Maksettu |  |
| `payment.remaining` | Remaining | Jäljellä |  |
| `payment.instruction` | Insert coins | Syötä kolikoita |  |
| `payment.instruction_with_card` | Insert coins or tap your card | Syötä kolikoita tai maksa kortilla |  |
| `payment.instruction_coin_down_with_card` | Coin payment unavailable — pay by card | Kolikkomaksu ei toimi — maksa kortilla |  |
| `payment.cancel` | Cancel | Peruuta |  |
| `preparing.hint1` | 1. Insert the hose through a slightly open window | 1. Työnnä letku hieman avatusta auton ikkunasta |  |
| `preparing.hint2` | 2. Turn on cabin air recirculation | 2. Kytke sisäilman kierrätys päälle |  |
| `preparing.hint3` | 3. Close all doors and wait outside | 3. Sulje kaikki ovet ja odota ulkona |  |
| `preparing.hint4` | 4. After treatment ends, the pump keeps spraying for {seconds} more sec — do not touch the hose | 4. Käsittelyn jälkeen pumppu suihkuttaa vielä {seconds} s — älä koske letkuun |  |
| `treating.cancel_title` | Stop the procedure? | Keskeytetäänkö käsittely? |  |
| `treating.cancel_body` | Payment is not refunded automatically. The procedure will be interrupted. | Maksua ei palauteta automaattisesti. Käsittely keskeytetään. |  |
| `treating.cancel_yes` ⚠ | Stop | Lopeta |  |
| `treating.cancel_no` | Continue | Jatka |  |
| `finished.title` | Treatment complete! | Käsittely valmis! |  |
| `finished.subtitle` | Your car interior has been treated with dry fog. | Autosi sisätila on käsitelty kuivalla sumulla. |  |
| `finished.returning` | Returning to start | Palataan alkuun |  |
| `finished.countdown` | {seconds}s | {seconds} s |  |
| `error.overheat.title` | Overheating | Ylikuumeneminen |  |
| `error.overheat.detail` | Temperature exceeded 240°C. All devices have been shut down. | Lämpötila ylitti 240°C. Kaikki laitteet on sammutettu. |  |
| `error.timeout.title` | Heating timeout | Lämmitys kesti liian kauan |  |
| `error.timeout.detail` ⚠ | Device did not reach 225°C within 600 seconds. | Laite ei saavuttanut 225°C:n lämpötilaa 600 sekunnissa. |  |
| `error.sensor.title` | Sensor error | Anturivirhe |  |
| `error.sensor.detail` | Temperature sensor is not responding. | Lämpötila-anturi ei vastaa. |  |
| `error.generic.title` | System error | Järjestelmävirhe |  |
| `error.generic.detail` | An unexpected error occurred. | Tapahtui odottamaton virhe. |  |
| `error.bus_unavailable.title` | Temporarily out of service | Tilapäisesti poissa käytöstä |  |
| `error.bus_unavailable.detail` | Payments are not being accepted right now. Please try again later. | Maksuja ei voida nyt vastaanottaa. Yritä myöhemmin uudelleen. |  |
| `error.coin_acceptor_unavailable.title` | Coin payment temporarily unavailable | Kolikkomaksu tilapäisesti pois käytöstä |  |
| `error.coin_acceptor_unavailable.detail` | Please use card payment or contact the service staff. | Maksa kortilla tai käänny henkilökunnan puoleen. |  |
| `error.heater_failure.title` | Device could not start | Laite ei käynnistynyt |  |
| `error.heater_failure.detail` ⚠ | The service was not provided. Please contact the service staff for a refund. | Palvelua ei suoritettu. Saat rahat takaisin henkilökunnalta. |  |
| `error.heater_sensor_fault.title` | Device could not start | Laite ei käynnistynyt |  |
| `error.heater_sensor_fault.detail` | The service was not provided. Please contact the service staff for a refund. | Palvelua ei suoritettu. Saat rahat takaisin henkilökunnalta. |  |
| `error.contact` | Please contact the service staff. | Käänny henkilökunnan puoleen. |  |
| `error.returning` | Returning to start | Palataan alkuun |  |
| `error.countdown` | {seconds}s | {seconds} s |  |
| `out_of_service.title` | Temporarily out of service | Tilapäisesti poissa käytöstä |  |
| `out_of_service.detail` | Payments are not being accepted. We apologise for the inconvenience. | Maksuja ei vastaanoteta. Pahoittelemme häiriötä. |  |

## Остальные

| ключ | en | перевод | замена (заполняет носитель) |
|---|---|---|---|
| `standby.tap_to_start` | Tap to start | Aloita napauttamalla |  |
| `standby.subtitle` ⚠ | DRY FOG | KUIVA SUMU |  |
| `language_select.title` | SELECT LANGUAGE | VALITSE KIELI |  |
| `select_flavor.title` | CHOOSE A FRAGRANCE | VALITSE TUOKSU |  |
| `select_flavor.hint` | Greyed-out fragrances are temporarily unavailable | Harmaat tuoksut eivät ole tilapäisesti saatavilla |  |
| `select_flavor.unavailable` | (unavailable) | (ei saatavilla) |  |
| `select_flavor.cancel` | Cancel | Peruuta |  |
| `preparing.title` | Preheating... | Esilämmitys... |  |
| `preparing.subtitle` | Heating the evaporator, please wait | Höyrystin lämpenee, odota hetki |  |
| `preparing.target` | Target {temp}°C | Tavoite {temp}°C |  |
| `preparing.cancel` | Cancel | Peruuta |  |
| `treating.compressor_title` | STARTING COMPRESSOR | KOMPRESSORI KÄYNNISTYY |  |
| `treating.compressor_sub` | Please wait | Odota hetki |  |
| `treating.treating_title` | TREATING VEHICLE INTERIOR | SISÄTILAN KÄSITTELY |  |
| `treating.treating_sub` | Fragrance is being sprayed — please wait | Tuoksua suihkutetaan — odota hetki |  |
| `treating.warning_title` | SESSION ENDING! | KÄSITTELY PÄÄTTYY! |  |
| `treating.warning_sub` | Get ready to remove the hose | Valmistaudu poistamaan letku |  |
| `treating.shutdown_title` | FINISHING UP | VIIMEISTELY |  |
| `treating.shutdown_sub` | Purging the system, please wait | Järjestelmää huuhdellaan, odota hetki |  |
| `treating.flavor` | Fragrance: {flavor} | Tuoksu: {flavor} |  |
| `treating.seconds` | {seconds} s | {seconds} s |  |
| `treating.cancel` | Cancel | Peruuta |  |

## Чек-лист

- [ ] Звучит естественно для экрана самообслуживания (коротко, без канцелярита).
- [ ] Вежливая форма обращения выдержана везде одинаково.
- [ ] Нет двусмысленности в инструкциях про шланг, окно, двери и ожидание снаружи (preparing.hint1–hint4).
- [ ] Фразы про деньги точны: оплата не возвращается автоматически при отмене (treating.cancel_body); при отказе — возврат только через персонал (error.*); ничего не обещано сверх английского текста.
- [ ] Единицы: секунды после {seconds}, «°C» после {temp}; слова в фигурных скобках не изменены.
- [ ] Диакритика и заглавные буквы в заголовках верны.
- [ ] Перевод «dry fog» (standby.subtitle, finished.subtitle) — принятый термин.

Подпись носителя языка, дата: ____________________
