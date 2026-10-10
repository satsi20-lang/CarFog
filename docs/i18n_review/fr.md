# Проверка перевода: Français (fr)

* Версия перевода (manifest): 1
* Статус: **draft**
* Дата листа: 2026-10-10
* **Черновик машинного перевода, требуется проверка носителем языка.**
  До проверки язык на боевых аппаратах не показывается.

Заполните столбец «замена» там, где перевод нужно исправить (пусто = верно).
Слова в фигурных скобках ({seconds}, {temp}, {flavor}) не менять.

## Пометки переводчика (сомнительные места)

* `standby.subtitle` — «Brouillard sec» — устоявшийся ли термин для услуги в салоне авто?
* `payment.instruction_coin_down_with_card` — Сокращено до «Pièces indisponibles — payez par carte».
* `preparing.hint2` — «Recyclage de l'air» — термин рециркуляции в авто.
* `treating.cancel_body` — Невозврат денег: проверить однозначность.

## Критичные (оплата, деньги, авария, инструкции)

| ключ | en | перевод | замена (заполняет носитель) |
|---|---|---|---|
| `payment.title` | PAYMENT | PAIEMENT |  |
| `payment.flavor` | Fragrance | Parfum |  |
| `payment.price` | Service price | Prix du service |  |
| `payment.paid` | Paid | Payé |  |
| `payment.remaining` | Remaining | Reste à payer |  |
| `payment.instruction` | Insert coins | Insérez des pièces |  |
| `payment.instruction_with_card` | Insert coins or tap your card | Insérez des pièces ou présentez votre carte |  |
| `payment.instruction_coin_down_with_card` ⚠ | Coin payment unavailable — pay by card | Pièces indisponibles — payez par carte |  |
| `payment.cancel` | Cancel | Annuler |  |
| `preparing.hint1` | 1. Insert the hose through a slightly open window | 1. Insérez le tuyau par une vitre légèrement ouverte |  |
| `preparing.hint2` ⚠ | 2. Turn on cabin air recirculation | 2. Activez le recyclage de l'air de l'habitacle |  |
| `preparing.hint3` | 3. Close all doors and wait outside | 3. Fermez toutes les portes et attendez à l'extérieur |  |
| `preparing.hint4` | 4. After treatment ends, the pump keeps spraying for {seconds} more sec — do not touch the hose | 4. Après le traitement, la pompe pulvérise encore {seconds} s — ne touchez pas le tuyau |  |
| `treating.cancel_title` | Stop the procedure? | Arrêter la procédure ? |  |
| `treating.cancel_body` ⚠ | Payment is not refunded automatically. The procedure will be interrupted. | Le paiement n'est pas remboursé automatiquement. La procédure sera interrompue. |  |
| `treating.cancel_yes` | Stop | Arrêter |  |
| `treating.cancel_no` | Continue | Continuer |  |
| `finished.title` | Treatment complete! | Traitement terminé ! |  |
| `finished.subtitle` | Your car interior has been treated with dry fog. | L'habitacle de votre voiture a été traité au brouillard sec. |  |
| `finished.returning` | Returning to start | Retour à l'accueil |  |
| `finished.countdown` | {seconds}s | {seconds} s |  |
| `error.overheat.title` | Overheating | Surchauffe |  |
| `error.overheat.detail` | Temperature exceeded 240°C. All devices have been shut down. | La température a dépassé 240°C. Tous les appareils ont été arrêtés. |  |
| `error.timeout.title` | Heating timeout | Délai de chauffe dépassé |  |
| `error.timeout.detail` | Device did not reach 225°C within 600 seconds. | L'appareil n'a pas atteint 225°C en 600 secondes. |  |
| `error.sensor.title` | Sensor error | Erreur de capteur |  |
| `error.sensor.detail` | Temperature sensor is not responding. | Le capteur de température ne répond pas. |  |
| `error.generic.title` | System error | Erreur système |  |
| `error.generic.detail` | An unexpected error occurred. | Une erreur inattendue s'est produite. |  |
| `error.bus_unavailable.title` | Temporarily out of service | Temporairement hors service |  |
| `error.bus_unavailable.detail` | Payments are not being accepted right now. Please try again later. | Les paiements ne sont pas acceptés pour le moment. Veuillez réessayer plus tard. |  |
| `error.coin_acceptor_unavailable.title` | Coin payment temporarily unavailable | Paiement par pièces temporairement indisponible |  |
| `error.coin_acceptor_unavailable.detail` | Please use card payment or contact the service staff. | Veuillez payer par carte ou vous adresser au personnel. |  |
| `error.heater_failure.title` | Device could not start | L'appareil n'a pas pu démarrer |  |
| `error.heater_failure.detail` | The service was not provided. Please contact the service staff for a refund. | Le service n'a pas été fourni. Adressez-vous au personnel pour un remboursement. |  |
| `error.heater_sensor_fault.title` | Device could not start | L'appareil n'a pas pu démarrer |  |
| `error.heater_sensor_fault.detail` | The service was not provided. Please contact the service staff for a refund. | Le service n'a pas été fourni. Adressez-vous au personnel pour un remboursement. |  |
| `error.contact` | Please contact the service staff. | Veuillez vous adresser au personnel. |  |
| `error.returning` | Returning to start | Retour à l'accueil |  |
| `error.countdown` | {seconds}s | {seconds} s |  |
| `out_of_service.title` | Temporarily out of service | Temporairement hors service |  |
| `out_of_service.detail` | Payments are not being accepted. We apologise for the inconvenience. | Les paiements ne sont pas acceptés. Veuillez nous excuser pour la gêne occasionnée. |  |

## Остальные

| ключ | en | перевод | замена (заполняет носитель) |
|---|---|---|---|
| `standby.tap_to_start` | Tap to start | Touchez pour démarrer |  |
| `standby.subtitle` ⚠ | DRY FOG | BROUILLARD SEC |  |
| `language_select.title` | SELECT LANGUAGE | CHOISISSEZ LA LANGUE |  |
| `select_flavor.title` | CHOOSE A FRAGRANCE | CHOISISSEZ UN PARFUM |  |
| `select_flavor.hint` | Greyed-out fragrances are temporarily unavailable | Les parfums grisés sont temporairement indisponibles |  |
| `select_flavor.unavailable` | (unavailable) | (indisponible) |  |
| `select_flavor.cancel` | Cancel | Annuler |  |
| `preparing.title` | Preheating... | Préchauffage... |  |
| `preparing.subtitle` | Heating the evaporator, please wait | Chauffage de l'évaporateur, veuillez patienter |  |
| `preparing.target` | Target {temp}°C | Objectif {temp}°C |  |
| `preparing.cancel` | Cancel | Annuler |  |
| `treating.compressor_title` | STARTING COMPRESSOR | DÉMARRAGE DU COMPRESSEUR |  |
| `treating.compressor_sub` | Please wait | Veuillez patienter |  |
| `treating.treating_title` | TREATING VEHICLE INTERIOR | TRAITEMENT DE L'HABITACLE |  |
| `treating.treating_sub` | Fragrance is being sprayed — please wait | Diffusion du parfum — veuillez patienter |  |
| `treating.warning_title` | SESSION ENDING! | FIN DE LA SÉANCE ! |  |
| `treating.warning_sub` | Get ready to remove the hose | Préparez-vous à retirer le tuyau |  |
| `treating.shutdown_title` | FINISHING UP | FINALISATION |  |
| `treating.shutdown_sub` | Purging the system, please wait | Purge du système, veuillez patienter |  |
| `treating.flavor` | Fragrance: {flavor} | Parfum : {flavor} |  |
| `treating.seconds` | {seconds} s | {seconds} s |  |
| `treating.cancel` | Cancel | Annuler |  |

## Чек-лист

- [ ] Звучит естественно для экрана самообслуживания (коротко, без канцелярита).
- [ ] Вежливая форма обращения выдержана везде одинаково.
- [ ] Нет двусмысленности в инструкциях про шланг, окно, двери и ожидание снаружи (preparing.hint1–hint4).
- [ ] Фразы про деньги точны: оплата не возвращается автоматически при отмене (treating.cancel_body); при отказе — возврат только через персонал (error.*); ничего не обещано сверх английского текста.
- [ ] Единицы: секунды после {seconds}, «°C» после {temp}; слова в фигурных скобках не изменены.
- [ ] Диакритика и заглавные буквы в заголовках верны.
- [ ] Перевод «dry fog» (standby.subtitle, finished.subtitle) — принятый термин.

Подпись носителя языка, дата: ____________________
