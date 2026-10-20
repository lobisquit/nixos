#!/usr/bin/env python3
"""Morning rain alert: if it will rain in the given time windows today,
send a message over XMPP. Runs once (started by a systemd timer) and exits.

Forecast: Open-Meteo (https://open-meteo.com), free, no API key.

Configuration: the YAML file $CREDENTIALS_DIRECTORY/configuration
(provided by systemd), like this

    latitude: 45.46
    longitude: 9.19
    xmpp_password: secret

Environment (set by the NixOS module):
  BOT_JID            bot account, e.g. meteo@lovisotto.it
  RECIPIENT          who receives the alert
  WINDOWS            time windows, e.g. "8-10,17-19" (local time, end excluded)
  MIN_PROBABILITY    % above which an hour counts as rainy (default 50)
  MIN_PRECIPITATION  mm in an hour above which it counts as rainy (default 0.2)
  TIMEZONE           e.g. Europe/Rome
"""
import asyncio
import datetime
import json
import logging
import os
import time
import urllib.parse
import urllib.request

import slixmpp
import yaml

logging.basicConfig(level=logging.INFO, format="%(levelname)s %(name)s: %(message)s")
log = logging.getLogger("rain_notifier")

JID = os.environ["BOT_JID"]
RECIPIENT = os.environ["RECIPIENT"]
TIMEZONE = os.environ.get("TIMEZONE", "Europe/Rome")
MIN_PROBABILITY = float(os.environ.get("MIN_PROBABILITY", "50"))
MIN_PRECIPITATION = float(os.environ.get("MIN_PRECIPITATION", "0.2"))
WINDOWS = [tuple(int(h) for h in window.split("-"))
           for window in os.environ.get("WINDOWS", "8-10,17-19").split(",")]

with open(os.path.join(os.environ["CREDENTIALS_DIRECTORY"], "configuration")) as f:
    CONF = yaml.safe_load(f)


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


def alert_text(forecast):
    """The message to send, or None if no window will be rainy."""
    lines = []
    for start, end in WINDOWS:
        hours = [forecast[h] for h in range(start, end) if h in forecast]
        rainy = [(mm, p) for mm, p in hours
                 if mm >= MIN_PRECIPITATION or p >= MIN_PROBABILITY]
        if rainy:
            max_mm = max(mm for mm, _ in hours)
            max_p = max(p for _, p in hours)
            lines.append(f"• {start}–{end}: fino a {max_mm:.1f} mm/h, probabilità {max_p:.0f}%")
        log.info("Window %d-%d: %s", start, end, hours)
    if not lines:
        return None
    return "☔ Oggi porta l'ombrello!\n" + "\n".join(lines)


# ---------------------------------------------------------------- XMPP

async def send(text):
    bot = slixmpp.ClientXMPP(JID, str(CONF["xmpp_password"]))

    async def on_start(_event):
        bot.send_presence()
        bot.send_message(mto=RECIPIENT, mbody=text, mtype="chat")
        log.info("Sent to %s", RECIPIENT)
        bot.disconnect()  # flushes the send queue first

    def on_failed_auth(_event):
        log.error("Authentication failed for %s", JID)
        bot.disconnect()

    bot.add_event_handler("session_start", on_start)
    bot.add_event_handler("failed_auth", on_failed_auth)
    bot.connect()
    await asyncio.wait_for(bot.disconnected, timeout=120)


def main():
    try:
        text = alert_text(fetch_forecast())
    except Exception as error:
        log.exception("Cannot read the forecast")
        text = f"⚠️ Non riesco a leggere le previsioni meteo: {error}"
    if text is None:
        log.info("No rain expected, nothing to send")
        return
    asyncio.run(send(text))


main()
