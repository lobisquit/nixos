#!/usr/bin/env python3
"""Evening reminder of the meal plan, sent to an XMPP group chat (MUC).
Runs once (started by a systemd timer) and exits.

The message has tonight's dinner and all the meals of tomorrow, taken
from the weekly plan in PLAN_FILE (YAML, one entry per weekday, see
xmpp/meal_plan.yaml).

Configuration: the YAML file $CREDENTIALS_DIRECTORY/configuration
(provided by systemd), like this

    xmpp_password: secret
    room_password: secret            # optional, only for protected rooms

Environment (set by the NixOS module):
  BOT_JID    bot account, e.g. dieta@lovisotto.it
  ROOM       group chat, e.g. piano_alimentare@conference.lovisotto.it
  NICK       nickname in the group chat
  PLAN_FILE  the weekly plan
  TIMEZONE   e.g. Europe/Rome
"""
import asyncio
import datetime
import logging
import os
import sys
from zoneinfo import ZoneInfo

import slixmpp
import yaml

logging.basicConfig(level=logging.INFO, format="%(levelname)s %(name)s: %(message)s")
log = logging.getLogger("meal_plan_notifier")

TIMEZONE = os.environ.get("TIMEZONE", "Europe/Rome")
PLAN_FILE = os.environ["PLAN_FILE"]

# datetime.weekday(): 0 is Monday
WEEKDAYS = ["lunedì", "martedì", "mercoledì", "giovedì", "venerdì", "sabato", "domenica"]
MEALS = {  # in the order they are shown
    "colazione": "☕ Colazione",
    "pranzo": "🥗 Pranzo",
    "spuntino": "🍎 Spuntino",
    "cena": "🍽️ Cena",
}


# ---------------------------------------------------------------- plan

def load_plan():
    with open(PLAN_FILE) as f:
        plan = yaml.safe_load(f)
    missing = [f"{day}/{meal}" for day in WEEKDAYS for meal in MEALS
               if not str((plan.get(day) or {}).get(meal) or "").strip()]
    if missing:
        raise ValueError(f"meals missing from the plan: {', '.join(missing)}")
    return plan


def build_message(plan, today):
    tomorrow = today + datetime.timedelta(days=1)
    tonight_day = WEEKDAYS[today.weekday()]
    tomorrow_day = WEEKDAYS[tomorrow.weekday()]

    lines = [f"🌙 Stasera ({tonight_day})",
             f"{MEALS['cena']}: {plan[tonight_day]['cena']}",
             "",
             f"📅 Domani ({tomorrow_day} {tomorrow.day})"]
    lines += [f"{label}: {plan[tomorrow_day][meal]}" for meal, label in MEALS.items()]
    return "\n".join(lines)


# ---------------------------------------------------------------- XMPP

class RoomSender(slixmpp.ClientXMPP):
    def __init__(self, jid, password, room, nick, room_password, text):
        super().__init__(jid, password)
        self.room, self.nick, self.room_password = room, nick, room_password
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
        log.error("Authentication failed for %s", self.boundjid.bare)
        self.disconnect()

    def on_room_stanza(self, stanza):
        if stanza["from"].bare != self.room or self.room_reply is None or self.room_reply.done():
            return
        if stanza["type"] == "error" or stanza["body"] == self.text:
            self.room_reply.set_result(stanza)

    async def on_start(self, _event):
        self.room_reply = self.loop.create_future()
        try:
            self.send_presence()
            # join the room without waiting: the server handles our stanzas
            # in order, so we are in the room before the message arrives
            join = self.make_presence(pto=f"{self.room}/{self.nick}")
            join["muc_join"]["history"]["maxstanzas"] = "0"
            if self.room_password:
                join["muc_join"]["password"] = self.room_password
            join.send()

            self.make_message(mto=self.room, mbody=self.text, mtype="groupchat").send()

            # the room sends our message back once it is posted
            reply = await asyncio.wait_for(self.room_reply, timeout=60)
            if reply["type"] == "error":
                log.error("Room error: %s %s", reply["error"]["condition"],
                          reply["error"]["text"])
            else:
                self.sent = True
                log.info("Sent to %s", self.room)
        except Exception:
            log.exception("XMPP error")
        finally:
            self.disconnect()


async def send(text):
    with open(os.path.join(os.environ["CREDENTIALS_DIRECTORY"], "configuration")) as f:
        conf = yaml.safe_load(f)
    bot = RoomSender(os.environ["BOT_JID"], str(conf["xmpp_password"]),
                     os.environ["ROOM"], os.environ.get("NICK", "Piano alimentare"),
                     str(conf.get("room_password") or ""), text)
    bot.connect()
    await asyncio.wait_for(bot.disconnected, timeout=300)
    return bot.sent


def main():
    today = datetime.datetime.now(ZoneInfo(TIMEZONE)).date()
    try:
        text = build_message(load_plan(), today)
    except Exception as error:
        log.exception("Cannot read the plan")
        text = f"⚠️ Non riesco a leggere il piano alimentare: {error}"
    log.info("Message:\n%s", text)
    if "--dry-run" in sys.argv:
        return
    if not asyncio.run(send(text)):
        raise SystemExit("Message not delivered")


if __name__ == "__main__":
    main()
