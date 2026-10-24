#!/usr/bin/env python3
"""Weekly list of the films coming out in Italian cinemas, sent to an XMPP
group chat (MUC). Runs once (started by a systemd timer) and exits.

The list covers DAYS days starting from today: run it on Wednesday with
DAYS=5 to get everything from Wednesday to Sunday (in Italy films usually
come out on Thursday, sometimes on Wednesday).

Source: TMDB (https://www.themoviedb.org), /discover/movie filtered by
Italian theatrical release dates (region=IT, release types 2 and 3).
Dates are user-contributed: big releases are reliable, small Italian or
arthouse films may be missing or have a stale date.

Configuration: the YAML file $CREDENTIALS_DIRECTORY/configuration
(provided by systemd), like this

    tmdb_token: eyJhbGciOi...        # "API Read Access Token" from TMDB settings → API
    xmpp_password: secret
    room_password: secret            # optional, only for protected rooms

Environment (set by the NixOS module):
  BOT_JID     bot account, e.g. uscite_cinema@lovisotto.it
  ROOM        group chat, e.g. cinema@conference.lovisotto.it
  NICK        nickname in the group chat
  DAYS        how many days to cover, starting today (default 5)
  MAX_MOVIES  at most this many films, the most popular ones (default 20)
  REGION      country of the release dates (default IT)
  LANGUAGE    language of titles and plots (default it-IT)
  TIMEZONE    e.g. Europe/Rome
"""
import asyncio
import datetime
import json
import logging
import os
import time
import urllib.parse
import urllib.request
from zoneinfo import ZoneInfo

import slixmpp
import yaml

logging.basicConfig(level=logging.INFO, format="%(levelname)s %(name)s: %(message)s")
log = logging.getLogger("cinema_notifier")

JID = os.environ["BOT_JID"]
ROOM = os.environ["ROOM"]
NICK = os.environ.get("NICK", "cinema")
DAYS = int(os.environ.get("DAYS", "5"))
MAX_MOVIES = int(os.environ.get("MAX_MOVIES", "20"))
REGION = os.environ.get("REGION", "IT")
LANGUAGE = os.environ.get("LANGUAGE", "it-IT")
TIMEZONE = os.environ.get("TIMEZONE", "Europe/Rome")

THEATRICAL = (2, 3)  # TMDB release types: theatrical (limited), theatrical
PLOT_LENGTH = 220
WEEKDAYS = ["lun", "mar", "mer", "gio", "ven", "sab", "dom"]
MONTHS = ["gennaio", "febbraio", "marzo", "aprile", "maggio", "giugno", "luglio",
          "agosto", "settembre", "ottobre", "novembre", "dicembre"]

with open(os.path.join(os.environ["CREDENTIALS_DIRECTORY"], "configuration")) as f:
    CONF = yaml.safe_load(f)


# ---------------------------------------------------------------- TMDB

def tmdb(path, **params):
    query = urllib.parse.urlencode({"language": LANGUAGE, **params})
    request = urllib.request.Request(
        f"https://api.themoviedb.org/3{path}?{query}",
        headers={"Authorization": f"Bearer {CONF['tmdb_token']}",
                 "Accept": "application/json"})
    for attempt in range(5):
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                return json.load(response)
        except Exception:
            if attempt == 4:
                raise
            log.exception("TMDB request %s failed, retrying in 60 s", path)
            time.sleep(60)


def discover(first, last):
    """Films with an Italian theatrical release between first and last, most popular first."""
    movies, page, pages = [], 1, 1
    while page <= pages and len(movies) < MAX_MOVIES:
        data = tmdb("/discover/movie",
                    region=REGION,
                    with_release_type="|".join(map(str, THEATRICAL)),
                    **{"release_date.gte": first.isoformat(),
                       "release_date.lte": last.isoformat()},
                    sort_by="popularity.desc",
                    include_adult="false",
                    page=page)
        movies += data["results"]
        pages = min(data.get("total_pages", 1), 5)
        page += 1
    return movies[:MAX_MOVIES]


def regional_release(details, first, last):
    """The Italian theatrical release date that falls in [first, last], if any."""
    for country in details.get("release_dates", {}).get("results", []):
        if country["iso_3166_1"] != REGION:
            continue
        for release in country["release_dates"]:
            if release["type"] not in THEATRICAL:
                continue
            day = datetime.date.fromisoformat(release["release_date"][:10])
            if first <= day <= last:
                return day
    return None


def describe(movie, first, last):
    """Details of a film as a dict, or None if its Italian date is outside the week."""
    details = tmdb(f"/movie/{movie['id']}", append_to_response="credits,release_dates")
    day = regional_release(details, first, last)
    if day is None:
        log.info("Skipping %s: no Italian release in the week", details.get("title"))
        return None
    directors = [person["name"] for person in details.get("credits", {}).get("crew", [])
                 if person.get("job") == "Director"]
    return {
        "id": details["id"],
        "title": details.get("title") or details.get("original_title"),
        "original_title": details.get("original_title"),
        "day": day,
        "genres": [genre["name"] for genre in details.get("genres", [])],
        "runtime": details.get("runtime") or 0,
        "directors": directors,
        "overview": (details.get("overview") or "").strip(),
        "popularity": movie.get("popularity", 0),
    }


# ---------------------------------------------------------------- message

def short(text, length=PLOT_LENGTH):
    if len(text) <= length:
        return text
    return text[:length].rsplit(" ", 1)[0].rstrip(",.;:") + "…"


def day_label(day):
    return f"{WEEKDAYS[day.weekday()]} {day.day}/{day.month}"


def date_range(first, last):
    if first.month == last.month:
        return f"{first.day}–{last.day} {MONTHS[last.month - 1]}"
    return f"{first.day} {MONTHS[first.month - 1]} – {last.day} {MONTHS[last.month - 1]}"


def format_movie(movie):
    title = movie["title"]
    if movie["original_title"] and movie["original_title"] != title:
        title += f" ({movie['original_title']})"
    facts = []
    if movie["genres"]:
        facts.append(", ".join(movie["genres"]))
    if movie["runtime"]:
        hours, minutes = divmod(movie["runtime"], 60)
        facts.append(f"{hours}h {minutes:02d}m" if hours else f"{minutes}m")
    if movie["directors"]:
        facts.append("di " + ", ".join(movie["directors"]))
    lines = [f"• {title} — {day_label(movie['day'])}"]
    if facts:
        lines.append("  " + " · ".join(facts))
    if movie["overview"]:
        lines.append("  " + short(movie["overview"]))
    lines.append(f"  https://www.themoviedb.org/movie/{movie['id']}")
    return "\n".join(lines)


def build_message(first, last):
    movies = [m for m in (describe(movie, first, last) for movie in discover(first, last)) if m]
    header = f"🎬 Uscite al cinema, {date_range(first, last)}"
    if not movies:
        return header + "\nNessuna uscita trovata su TMDB."
    movies.sort(key=lambda m: (m["day"], -m["popularity"]))
    return header + "\n\n" + "\n\n".join(format_movie(m) for m in movies)


# ---------------------------------------------------------------- XMPP

class RoomSender(slixmpp.ClientXMPP):
    def __init__(self, text):
        super().__init__(JID, str(CONF["xmpp_password"]))
        self.text = text
        self.sent = False
        self.room_reply = None
        self.register_plugin("xep_0045")  # group chats (muc_join)
        self.add_event_handler("session_start", self.on_start)
        self.add_event_handler("failed_auth", self.on_failed_auth)
        # answers from the room: the echo of our message, or an error
        for event in ("groupchat_message", "message_error", "presence_error"):
            self.add_event_handler(event, self.on_room_stanza)

    def on_failed_auth(self, _event):
        log.error("Authentication failed for %s", JID)
        self.disconnect()

    def on_room_stanza(self, stanza):
        if stanza["from"].bare != ROOM or self.room_reply is None or self.room_reply.done():
            return
        if stanza["type"] == "error" or stanza["body"] == self.text:
            self.room_reply.set_result(stanza)

    async def on_start(self, _event):
        self.room_reply = self.loop.create_future()
        try:
            self.send_presence()
            # join the room without waiting: the server handles our stanzas
            # in order, so we are in the room before the message arrives
            join = self.make_presence(pto=f"{ROOM}/{NICK}")
            join["muc_join"]["history"]["maxstanzas"] = "0"
            if CONF.get("room_password"):
                join["muc_join"]["password"] = str(CONF["room_password"])
            join.send()

            self.make_message(mto=ROOM, mbody=self.text, mtype="groupchat").send()

            # the room sends our message back once it is posted
            reply = await asyncio.wait_for(self.room_reply, timeout=60)
            if reply["type"] == "error":
                log.error("Room error: %s %s", reply["error"]["condition"],
                          reply["error"]["text"])
            else:
                self.sent = True
                log.info("Sent to %s", ROOM)
        except Exception:
            log.exception("XMPP error")
        finally:
            self.disconnect()


async def send(text):
    bot = RoomSender(text)
    bot.connect()
    await asyncio.wait_for(bot.disconnected, timeout=300)
    return bot.sent


def main():
    first = datetime.datetime.now(ZoneInfo(TIMEZONE)).date()
    last = first + datetime.timedelta(days=DAYS - 1)
    try:
        text = build_message(first, last)
    except Exception as error:
        log.exception("Cannot read the releases")
        text = f"⚠️ Non riesco a leggere le uscite al cinema da TMDB: {error}"
    log.info("Message:\n%s", text)
    if not asyncio.run(send(text)):
        raise SystemExit("Message not delivered")


if __name__ == "__main__":
    main()
