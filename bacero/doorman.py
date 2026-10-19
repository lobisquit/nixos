import asyncio
import os
import queue
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

import serial
import slixmpp


# all settings are read once, at startup: a missing one stops the script now
SERIAL_DEV = os.environ['SERIAL_DEV']
SERIAL_BAUD_RATE = int(os.environ['SERIAL_BAUD_RATE'])
TMP_PATH = Path(os.environ['TMP_PATH'])
RECORD_COMMAND = os.environ['RECORD_COMMAND']
SEND_COMMAND = os.environ['SEND_COMMAND']
REBOOT_COMMAND = os.environ['REBOOT_COMMAND']
VIDEO_INTERFACE = os.environ['VIDEO_INTERFACE']
AUDIO_INTERFACE = os.environ['AUDIO_INTERFACE']
XMPP_JID = os.environ['XMPP_JID']
XMPP_PASSWORD = os.environ['XMPP_PASSWORD'].strip()
XMPP_ROOM = os.environ['XMPP_ROOM']
XMPP_NICK = os.environ['XMPP_NICK']

# run ffmpeg with the lowest CPU and disk priority, so that it
# does not slow down the other services on the server
FFMPEG = ['nice', '-n', '19', 'ionice', '-c', '3', 'ffmpeg']


class VideoSender(slixmpp.ClientXMPP):
    """Short-lived XMPP client: join the room, upload the video, post its link."""

    def __init__(self, video_path):
        super().__init__(XMPP_JID, XMPP_PASSWORD)
        self.video_path = video_path
        self.sent = False
        self.register_plugin('xep_0030')  # service discovery (finds upload service)
        self.register_plugin('xep_0045')  # group chats
        self.register_plugin('xep_0066')  # file links (OOB), shown inline by clients
        self.register_plugin('xep_0363')  # HTTP file upload
        self.add_event_handler('session_start', self.on_start)
        self.add_event_handler('failed_auth', lambda _: self.disconnect())

    async def on_start(self, _event):
        try:
            await self.plugin['xep_0045'].join_muc_wait(
                XMPP_ROOM, XMPP_NICK, maxstanzas=0, timeout=60)
            url = await self.plugin['xep_0363'].upload_file(
                self.video_path, timeout=600)
            message = self.make_message(mto=XMPP_ROOM, mbody=url, mtype='groupchat')
            message['oob']['url'] = url
            message.send()
            self.sent = True
        finally:
            self.disconnect()


async def send_video(video_path):
    client = VideoSender(video_path)
    client.connect()
    # give up after 15 minutes, e.g. if the server is unreachable
    await asyncio.wait_for(client.disconnected, timeout=900)
    return client.sent


def convert_and_send(jobs):
    """Worker thread: merge audio and video, then send the result."""
    while True:
        recording_dir = jobs.get()
        try:
            subprocess.run([
                *FFMPEG,
                '-y', # force overwrite
                '-hide_banner',
                '-loglevel', 'error',
                '-i', recording_dir / 'video.mp4',
                '-i', recording_dir / 'audio.wav',
                '-c:v', 'libx264',
                '-preset', 'medium',
                '-crf', '26', # lower = better quality and bigger file
                '-profile:v', 'high',
                # 15 fps and at most 720p are enough for a door camera
                '-vf', "fps=15,scale=-2:'min(720,ih)',format=yuv420p",
                '-c:a', 'aac',
                '-ac', '1',
                '-b:a', '64k',
                # metadata at the start: playback begins before the download ends
                '-movflags', '+faststart',
                recording_dir / 'combined.mp4'], check=True)

            print('Sending recording to the XMPP room', flush=True)
            if asyncio.run(send_video(recording_dir / 'combined.mp4')):
                print('Recording sent', flush=True)
            else:
                print('Could not send recording', flush=True)
        except Exception as ex:
            print('Could not convert or send recording:', repr(ex), flush=True)
        finally:
            shutil.rmtree(recording_dir, ignore_errors=True)


def stop(process):
    if process:
        process.terminate()
        process.wait()


if __name__ == '__main__':
    print(f"Using {TMP_PATH} as temporary directory")

    jobs = queue.Queue()
    threading.Thread(target=convert_and_send, args=(jobs,), daemon=True).start()

    with serial.Serial(SERIAL_DEV, SERIAL_BAUD_RATE, timeout=0) as ser:
        ser.setRTS(False)
        ser.setDTR(False)

        audio_process = None
        video_process = None
        recording_dir = None

        # wait for the first 'b' after the reboot caused by the connection
        while ser.read(1) != b'b':
            time.sleep(0.001)

        print('Startup byte detected from board', flush=True)

        while True:
            time.sleep(0.010)

            # blocking call for next character
            try:
                next_byte = ser.read(1)
            except serial.SerialException as ex:
                # raise the exception if the serial device failed but
                # it is still there
                if Path(SERIAL_DEV).exists():
                    raise ex
                else:
                    print('Could not read command: serial device disappeared',
                          flush=True)
                    sys.exit(0)

            if len(next_byte) == 0:
                continue

            command = next_byte.decode('ascii')
            print('Loaded command:', command, flush=True)

            if command == RECORD_COMMAND:
                # discard a previous recording that was never sent
                stop(audio_process)
                stop(video_process)
                if recording_dir:
                    shutil.rmtree(recording_dir, ignore_errors=True)

                # each recording has its own folder, so a new one can start
                # while the previous one is still being converted and sent
                recording_dir = Path(tempfile.mkdtemp(dir=TMP_PATH))

                print('Started recording', flush=True)
                subprocess.run(['amixer', 'set', 'Capture', 'cap'])
                subprocess.run(['amixer', '-M', 'set', 'Capture', '15%'])

                audio_process = subprocess.Popen([
                    *FFMPEG,
                    '-y', # force overwrite
                    '-hide_banner',
                    '-loglevel', 'error',
                    '-f', 'pulse',
                    '-i', AUDIO_INTERFACE,
                    '-t', '00:10:00',
                    recording_dir / 'audio.wav'
                ])

                video_process = subprocess.Popen([
                    *FFMPEG,
                    '-y', # force overwrite
                    '-hide_banner',
                    '-loglevel', 'error',
                    '-f', 'v4l2',
                    '-i', VIDEO_INTERFACE,
                    '-t', '00:10:00',
                    # fast, high-quality capture: the final compression
                    # happens later, in the worker thread
                    '-c:v', 'libx264',
                    '-preset', 'ultrafast',
                    '-crf', '18',
                    recording_dir / 'video.mp4'
                ])

            if command == REBOOT_COMMAND:
                stop(audio_process)
                stop(video_process)

                audio_process = None
                video_process = None

            if command == SEND_COMMAND and recording_dir:
                stop(audio_process)
                stop(video_process)

                audio_process = None
                video_process = None

                # conversion and sending happen in the worker thread
                jobs.put(recording_dir)
                recording_dir = None
