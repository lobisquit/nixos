#!/usr/bin/env python3
"""Rain alert over XMPP. Runs once (started by a systemd timer) and exits.

    xmpp_rain_notifier.py morning
        Checks every window in WINDOWS; if any will be rainy, sends one
        message listing them. Remembers which windows were announced.

    xmpp_rain_notifier.py afternoon
        Checks only AFTERNOON_WINDOWS and sends a message only for the
        windows that are rainy now but were NOT announced this morning
        (forecast changed). Stays silent otherwise.

Forecast: Open-Meteo (https://open-meteo.com), free, no API key.

Configuration: the YAML file $CREDENTIALS_DIRECTORY/configuration
(provided by systemd), like this

    latitude: 45.46
    longitude: 9.19
    xmpp_password: secret

Environment (set by the NixOS module):
  BOT_JID            bot account, e.g. meteo@lovisotto.it
  RECIPIENTS         who receives the alert, comma separated
  WINDOWS            morning windows, e.g. "8-10,17-19" (local time, end excluded)
  AFTERNOON_WINDOWS  afternoon windows, e.g. "17-19"
  MIN_PROBABILITY    % above which an hour counts as rainy (default 50)
  MIN_PRECIPITATION  mm in an hour above which it counts as rainy (default 0.2)
  TIMEZONE           e.g. Europe/Rome
  STATE_DIRECTORY    (set by systemd) remembers the morning announcement
"""
import asyncio
import datetime
import json
import logging
import os
import sys
import time
import urllib.parse
import urllib.request
from zoneinfo import ZoneInfo

import slixmpp
import yaml

logging.basicConfig(level=logging.INFO, format="%(levelname)s %(name)s: %(message)s")
log = logging.getLogger("rain_notifier")

JID = os.environ["BOT_JID"]
RECIPIENTS = [jid.strip() for jid in os.environ["RECIPIENTS"].split(",") if jid.strip()]
TIMEZONE = os.environ.get("TIMEZONE", "Europe/Rome")
MIN_PROBABILITY = float(os.environ.get("MIN_PROBABILITY", "50"))
MIN_PRECIPITATION = float(os.environ.get("MIN_PRECIPITATION", "0.2"))
STATE_FILE = os.path.join(os.environ["STATE_DIRECTORY"], "announced.json")


def parse_windows(text):
    """"8-10,17-19" -> [(8, 10), (17, 19)]"""
    return [tuple(int(h) for h in window.split("-"))
            for window in text.split(",") if window.strip()]


WINDOWS = parse_windows(os.environ.get("WINDOWS", "8-10,17-19"))
AFTERNOON_WINDOWS = parse_windows(os.environ.get("AFTERNOON_WINDOWS", "17-19"))

with open(os.path.join(os.environ["CREDENTIALS_DIRECTORY"], "configuration")) as f:
    CONF = yaml.safe_load(f)


def today():
    return datetime.datetime.now(ZoneInfo(TIMEZONE)).date().isoformat()


# ---------------------------------------------------------------- state

def load_announced():
    """Windows announced by this morning's run, e.g. ["17-19"]."""
    try:
        with open(STATE_FILE) as f:
            state = json.load(f)
    except (FileNotFoundError, ValueError):
        return []
    # Yesterday's state (or a missed morning run) means nothing was announced.
    return state.get("announced", []) if state.get("date") == today() else []


def save_announced(announced):
    tmp = STATE_FILE + ".tmp"
    with open(tmp, "w") as f:
        json.dump({"date": today(), "announced": announced}, f)
    os.replace(tmp, STATE_FILE)


# ---------------------------------------------------------------- forecast

def fetch_forecast():
    """Today's hourly forecast: {hour: (precipitation mm, probability %)}.

    Open-Meteo hourly values refer to the PRECEDING hour: the value at
    09:00 is the rain between 08:00 and 09:00.
    """
    query = urllib.parse.urlencode({
        "latitude": CONF["latitude"],
        "longitude": CONF["longitude"],
        "hourly": "precipitation,precipitation_probability",
        "timezone": TIMEZONE,
        "forecast_days": 1,
    })
    url = f"https://api.open-meteo.com/v1/forecast?{query}"
    for attempt in range(5):
        try:
            with urllib.request.urlopen(url, timeout=30) as response:
                data = json.load(response)["hourly"]
            break
        except Exception:
            if attempt == 4:
                raise
            log.exception("Forecast download failed, retrying in 60 s")
            time.sleep(60)

    forecast = {}
    for stamp, mm, probability in zip(data["time"], data["precipitation"],
                                      data["precipitation_probability"]):
        end = datetime.datetime.fromisoformat(stamp)
        start_hour = (end - datetime.timedelta(hours=1)).hour
        forecast[start_hour] = (mm or 0.0, probability or 0)
    return forecast


def rainy_windows(forecast, windows):
    """{"17-19": "fino a 1.4 mm/h, probabilità 80%"} for the rainy windows only."""
    rainy = {}
    for start, end in windows:
        hours = [forecast[h] for h in range(start, end) if h in forecast]
        log.info("Window %d-%d: %s", start, end, hours)
        if any(mm >= MIN_PRECIPITATION or p >= MIN_PROBABILITY for mm, p in hours):
            max_mm = max(mm for mm, _ in hours)
            max_p = max(p for _, p in hours)
            rainy[f"{start}-{end}"] = f"fino a {max_mm:.1f} mm/h, probabilità {max_p:.0f}%"
    return rainy


def bullets(rainy):
    return "\n".join(f"• {name.replace('-', '–')}: {details}"
                     for name, details in rainy.items())


def morning(forecast):
    rainy = rainy_windows(forecast, WINDOWS)
    save_announced(list(rainy))
    if not rainy:
        return None
    return "☔ Oggi porta l'ombrello!\n" + bullets(rainy)


def afternoon(forecast):
    announced = load_announced()
    rainy = rainy_windows(forecast, AFTERNOON_WINDOWS)
    new = {name: details for name, details in rainy.items() if name not in announced}
    if not new:
        return None
    save_announced(announced + list(new))  # don't repeat it on a later run
    return "🌦️ Cambio di programma, è prevista pioggia:\n" + bullets(new)


# ---------------------------------------------------------------- XMPP

async def send(text):
    bot = slixmpp.ClientXMPP(JID, str(CONF["xmpp_password"]))

    async def on_start(_event):
        bot.send_presence()
        for recipient in RECIPIENTS:
            bot.send_message(mto=recipient, mbody=text, mtype="chat")
            log.info("Sent to %s", recipient)
        bot.disconnect()  # flushes the send queue first

    def on_failed_auth(_event):
        log.error("Authentication failed for %s", JID)
        bot.disconnect()

    bot.add_event_handler("session_start", on_start)
    bot.add_event_handler("failed_auth", on_failed_auth)
    bot.connect()
    await asyncio.wait_for(bot.disconnected, timeout=120)


def main():
    modes = {"morning": morning, "afternoon": afternoon}
    mode = sys.argv[1] if len(sys.argv) > 1 else "morning"
    if mode not in modes:
        sys.exit(f"Unknown mode {mode!r}, use one of: {', '.join(modes)}")
    try:
        text = modes[mode](fetch_forecast())
    except Exception as error:
        log.exception("Cannot read the forecast")
        text = f"⚠️ Non riesco a leggere le previsioni meteo: {error}"
    if text is None:
        log.info("Nothing to send")
        return
    asyncio.run(send(text))


if __name__ == "__main__":
    main()
