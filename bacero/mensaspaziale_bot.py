#!/usr/bin/env python3

import glob
import json
import os
import urllib.parse
import urllib.request
from datetime import date, datetime

## Date calculations

def get_iso_week(d: date) -> int:
    return d.isocalendar()[1]


def get_menu_week(d: date) -> int:
    WEEK_OFFSET = 2
    return (get_iso_week(d) + WEEK_OFFSET) % 4


def get_day_of_week(d: date) -> int:
    # Monday=0 ... Friday=4
    return d.weekday()


def get_italian_day(d: date) -> str:
    names = ["Lunedì", "Martedì", "Mercoledì", "Giovedì", "Venerdì", "Sabato", "Domenica"]
    return names[d.weekday()]

## Data retrieval

def fetch_menu(d: date) -> dict:
    cache_path = f"/tmp/mensa_{d.isoformat()}.json"

    # Delete any old cache files from previous days
    for old_file in glob.glob("/tmp/mensa_*.json"):
        if old_file != cache_path:
            os.remove(old_file)
            print(f"Deleted old cache: {old_file}")

    if os.path.exists(cache_path):
        file_date = datetime.fromtimestamp(os.path.getmtime(cache_path)).date()
        if file_date == d:
            print(f"Using cached data from {cache_path}")
            with open(cache_path, "r") as f:
                return json.load(f)
        else:
            print(f"Cache is from {file_date}, downloading fresh data...")

    week = get_menu_week(d)
    day  = get_day_of_week(d)

    base_url = os.environ['BASE_URL']
    params = urllib.parse.urlencode({
        "queries[0]": json.dumps({"method": "between", "attribute": "week", "values": [week, week]}),
        "queries[1]": json.dumps({"method": "between", "attribute": "day",  "values": [day,  day]}),
    })
    url = f"{base_url}?{params}"

    print(f"Fetching menu for {get_italian_day(d)} (week={week}, day={day})...")
    req = urllib.request.Request(url, headers={"X-Appwrite-Project": os.environ['APPWRITE_PROJECT']})
    with urllib.request.urlopen(req) as resp:
        data = json.loads(resp.read().decode())

    with open(cache_path, "w") as f:
        json.dump(data, f, ensure_ascii=False, indent=2)
    print(f"Cached to {cache_path}")

    return data

## Telegram message format and send

def escape_mdv2(text: str) -> str:
    # Characters that must be escaped in MarkdownV2 outside of formatting tags
    for ch in r"\_[]()~`>#+-=|{}.!":
        text = text.replace(ch, f"\\{ch}")
    return text


def format_markdown(data: dict, d: date) -> str:
    if not data.get("rows"):
        return "*Menu non disponibile*"

    row = data["rows"][0]

    def render_section(title: str, dishes) -> str:
        if isinstance(dishes, str):
            dishes = [dishes]
        if not dishes:
            return ""
        lines = [f"*{escape_mdv2(title)}*"]
        for dish in dishes:
            lines.append(f"• {escape_mdv2(dish)}")
        return "\n".join(lines)

    sections = []
    sections.append(f"*{escape_mdv2(f'Menu del {get_italian_day(d)} {d.strftime("%d/%m/%Y")}') }*")
    sections.append(render_section("Primi Piatti",         row.get("primi_piatti", [])))
    sections.append(render_section("Secondi Piatti",       row.get("secondi_piatti", [])))
    sections.append(render_section("Contorni",             row.get("contorni", [])))
    sections.append(render_section("Piatto dello Chef",    row.get("piatto_dello_chef", "")))
    sections.append(render_section("Alternative Variabili",row.get("alternative_variabili", [])))

    return "\n\n".join(s for s in sections if s)


def send_telegram(text: str, bot_token: str, chat_ids: list[str]) -> None:
    url = f"https://api.telegram.org/bot{bot_token}/sendMessage"
    for chat_id in chat_ids:
        payload = json.dumps({
            "chat_id": chat_id.strip(),
            "text": text,
            "parse_mode": "MarkdownV2",
        }).encode()

        print(f"Sending to {str(chat_id)[:3]}...")

        req = urllib.request.Request(url, data=payload, headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(req) as resp:
            result = json.loads(resp.read().decode())
            if result.get("ok"):
                print(f"Message sent to {chat_id}")
            else:
                print(f"Failed to send to {chat_id}: {result}")


if __name__ == "__main__":
    date_override = os.environ.get("MENSA_DATE")
    if date_override:
        today = date.fromisoformat(date_override)
        print(f"Date override: {today}")
    else:
        today = date.today()

    if today.weekday() > 4:
        print("Oggi e' weekend, la mensa e' chiusa!")
    else:
        data = fetch_menu(today)
        md   = format_markdown(data, today)
        print("\n" + md)

        bot_token = os.environ.get("TELEGRAM_BOT_TOKEN")
        chat_ids  = os.environ.get("TELEGRAM_CHAT_IDS")
        if bot_token and chat_ids:
            send_telegram(md, bot_token, chat_ids.split(","))
        else:
            print("TELEGRAM_BOT_TOKEN or TELEGRAM_CHAT_IDS not set, skipping Telegram.")
