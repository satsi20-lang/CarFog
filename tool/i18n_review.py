#!/usr/bin/env python3
"""Лист проверки перевода для носителя языка (docs/i18n.md).

  python3 tool/i18n_review.py <код> [<код> ...]   — docs/i18n_review/<код>.md
  python3 tool/i18n_review.py --all               — все языки со статусом draft и файлом

Только стандартная библиотека. Лист: шапка (язык, версия, дата, статус),
пометки переводчика, таблица «ключ | en | перевод | замена» — сначала
КРИТИЧНЫЕ ключи (оплата, ошибки, «не работает», отмена процедуры,
инструкции про шланг, завершение), потом остальные, — и чек-лист.
"""
import datetime
import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
I18N = os.path.join(ROOT, "assets", "i18n")
OUT = os.path.join(ROOT, "docs", "i18n_review")

CRITICAL_PREFIXES = ("payment.", "error.", "out_of_service.", "treating.cancel_", "preparing.hint", "finished.")

# Пометки переводчика (машинный черновик): места, где носителю стоит
# посмотреть особенно внимательно. Не исчерпывающий список.
NOTES = {
    "de": {
        "standby.subtitle": "«Trockennebel» — так ли называют услугу сухого тумана для салона на немецком рынке?",
        "preparing.hint2": "«Umluft» — проверить, что это понятный термин рециркуляции в авто.",
        "treating.warning_sub": "Перевод «Get ready to remove the hose» сокращён до «Bereit zum Entnehmen des Schlauchs».",
        "error.heater_failure.detail": "Возврат денег: «Für eine Erstattung wenden Sie sich bitte an das Personal» — без обещания автоматического возврата.",
    },
    "fr": {
        "standby.subtitle": "«Brouillard sec» — устоявшийся ли термин для услуги в салоне авто?",
        "payment.instruction_coin_down_with_card": "Сокращено до «Pièces indisponibles — payez par carte».",
        "preparing.hint2": "«Recyclage de l'air» — термин рециркуляции в авто.",
        "treating.cancel_body": "Невозврат денег: проверить однозначность.",
    },
    "fi": {
        "standby.subtitle": "«Kuiva sumu» — есть ли устоявшийся термин (kuivasumu?)",
        "payment.paid": "«Maksettu» длиннее en в 2 раза (en — 4 символа); макет проверен.",
        "treating.cancel_yes": "«Lopeta» вместо «Keskeytä» — ради длины; естественно ли для кнопки остановки?",
        "error.heater_failure.detail": "«Saat rahat takaisin henkilökunnalta» — не звучит ли как обещание возврата сверх en?",
        "error.timeout.detail": "«225°C:n» — падежное окончание после числа.",
    },
    "sv": {
        "standby.subtitle": "«Torrdimma» — термин услуги?",
        "treating.shutdown_sub": "«Systemet blåses rent» — продувка системы.",
        "payment.instruction_with_card": "«håll fram kortet» — естественно ли для бесконтактной оплаты (часто «blippa»)?",
    },
    "pl": {
        "standby.subtitle": "«Sucha mgła» — термин услуги.",
        "standby.tap_to_start": "Тон: инфинитивы («Dotknąć», «Wrzucić», «Włożyć») вместо формы на «ты»; проверить, естественно ли для автомата.",
        "treating.treating_title": "«TRWA ZABIEG WNĘTRZA AUTA» — подходящее ли слово «zabieg».",
        "treating.cancel_yes": "«Przerwać» длиннее en в 2 раза (en «Stop»); макет проверен.",
        "error.heater_failure.detail": "Возврат: «W sprawie zwrotu prosimy zwrócić się do obsługi».",
    },
    "lv": {
        "standby.subtitle": "«Sausā migla» — термин услуги?",
        "standby.tap_to_start": "Длиннее en в 2 раза; макет проверен.",
        "payment.paid": "«Iemaksāts» (внесено) — длиннее en в 2,25 раза; макет проверен.",
        "treating.cancel_yes": "«Pārtraukt» — длиннее en в 2,25 раза; макет проверен.",
        "error.heater_failure.detail": "Возврат: «Par naudas atmaksu vērsieties pie personāla».",
    },
    "lt": {
        "standby.subtitle": "«Sausas rūkas» — термин услуги?",
        "standby.tap_to_start": "Длиннее en в 2,25 раза; макет проверен.",
        "preparing.hint3": "«dureles» — двери автомобиля (уменьшительная форма) — верно ли?",
        "treating.cancel_yes": "«Nutraukti» — длиннее en в 2,25 раза; макет проверен.",
        "error.heater_failure.detail": "Возврат: «Dėl pinigų grąžinimo kreipkitės į personalą».",
    },
}

CHECKLIST = [
    "Звучит естественно для экрана самообслуживания (коротко, без канцелярита).",
    "Вежливая форма обращения выдержана везде одинаково.",
    "Нет двусмысленности в инструкциях про шланг, окно, двери и ожидание снаружи (preparing.hint1–hint4).",
    "Фразы про деньги точны: оплата не возвращается автоматически при отмене (treating.cancel_body); при отказе — возврат только через персонал (error.*); ничего не обещано сверх английского текста.",
    "Единицы: секунды после {seconds}, «°C» после {temp}; слова в фигурных скобках не изменены.",
    "Диакритика и заглавные буквы в заголовках верны.",
    "Перевод «dry fog» (standby.subtitle, finished.subtitle) — принятый термин.",
]


def load(code):
    with open(os.path.join(I18N, code + ".json"), encoding="utf-8") as f:
        return json.load(f)


def cell(s):
    return s.replace("|", "\\|").replace("\n", " ")


def render(code, manifest, en, tr, today):
    info = manifest["languages"][code]
    notes = NOTES.get(code, {})
    crit = [k for k in en if k.startswith(CRITICAL_PREFIXES)]
    rest = [k for k in en if k not in crit]
    lines = [
        f"# Проверка перевода: {info['name']} ({code})",
        "",
        f"* Версия перевода (manifest): {info['version']}",
        f"* Статус: **{info['status']}**",
        f"* Дата листа: {today}",
        "* **Черновик машинного перевода, требуется проверка носителем языка.**",
        "  До проверки язык на боевых аппаратах не показывается.",
        "",
        "Заполните столбец «замена» там, где перевод нужно исправить (пусто = верно).",
        "Слова в фигурных скобках ({seconds}, {temp}, {flavor}) не менять.",
        "",
    ]
    if notes:
        lines += ["## Пометки переводчика (сомнительные места)", ""]
        lines += [f"* `{k}` — {v}" for k, v in notes.items()]
        lines.append("")
    for title, keys in (("Критичные (оплата, деньги, авария, инструкции)", crit), ("Остальные", rest)):
        lines += [f"## {title}", "", "| ключ | en | перевод | замена (заполняет носитель) |", "|---|---|---|---|"]
        lines += [f"| `{k}`{' ⚠' if k in notes else ''} | {cell(en[k])} | {cell(tr.get(k, ''))} |  |" for k in keys]
        lines.append("")
    lines += ["## Чек-лист", ""]
    lines += [f"- [ ] {c}" for c in CHECKLIST]
    lines += ["", "Подпись носителя языка, дата: ____________________", ""]
    return "\n".join(lines)


def main(argv):
    with open(os.path.join(I18N, "manifest.json"), encoding="utf-8") as f:
        manifest = json.load(f)
    if argv == ["--all"]:
        codes = [c for c, v in manifest["languages"].items()
                 if v["status"] == "draft" and os.path.exists(os.path.join(I18N, c + ".json"))]
    else:
        codes = argv
    if not codes:
        print(__doc__)
        return 2
    en = load("en")
    os.makedirs(OUT, exist_ok=True)
    today = datetime.date.today().isoformat()
    for code in codes:
        if code not in manifest["languages"]:
            print(f"нет языка {code} в manifest.json", file=sys.stderr)
            return 1
        path = os.path.join(OUT, code + ".md")
        with open(path, "w", encoding="utf-8") as f:
            f.write(render(code, manifest, en, load(code), today))
        print(path)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
