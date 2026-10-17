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


def env(name):
    return os.environ[name]


class VideoSender(slixmpp.ClientXMPP):
    """Short-lived XMPP client: join the room, upload the video, post its link."""

    def __init__(self, video_path):
        super().__init__(env('XMPP_JID'), env('XMPP_PASSWORD').strip())
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
            room = env('XMPP_ROOM')
            await self.plugin['xep_0045'].join_muc_wait(
                room, env('XMPP_NICK'), maxstanzas=0, timeout=60)
            url = await self.plugin['xep_0363'].upload_file(
                self.video_path, timeout=600)
            message = self.make_message(mto=room, mbody=url, mtype='groupchat')
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
                'ffmpeg',
                '-y', # force overwrite
                '-hide_banner',
                '-loglevel', 'error',
                '-i', recording_dir / 'video.mp4',
                '-i', recording_dir / 'audio.mp3',
                '-c:v', 'libx264',
                '-profile:v', 'baseline',
                '-c:a', 'aac',
                '-ar', '44100',
                '-ac', '2',
                '-b:a', '128k',
                '-vf', 'format=yuv420p',
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
    print(f"Using {Path(env('TMP_PATH'))} as temporary directory")

    jobs = queue.Queue()
    threading.Thread(target=convert_and_send, args=(jobs,), daemon=True).start()

    with serial.Serial(env('SERIAL_DEV'), env('SERIAL_BAUD_RATE'), timeout=0) as ser:
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
                if Path(env('SERIAL_DEV')).exists():
                    raise ex
                else:
                    print('Could not read command: serial device disappeared',
                          flush=True)
                    sys.exit(0)

            if len(next_byte) == 0:
                continue

            command = next_byte.decode('ascii')
            print('Loaded command:', command, flush=True)

            if command == env('RECORD_COMMAND'):
                video_if = env('VIDEO_INTERFACE')
                audio_if = env('AUDIO_INTERFACE')

                # discard a previous recording that was never sent
                stop(audio_process)
                stop(video_process)
                if recording_dir:
                    shutil.rmtree(recording_dir, ignore_errors=True)

                # each recording has its own folder, so a new one can start
                # while the previous one is still being converted and sent
                recording_dir = Path(tempfile.mkdtemp(dir=env('TMP_PATH')))

                print('Started recording', flush=True)
                subprocess.run(['amixer', 'set', 'Capture', 'cap'])
                subprocess.run(['amixer', '-M', 'set', 'Capture', '15%'])

                audio_process = subprocess.Popen([
                    'ffmpeg',
                    '-y', # force overwrite
                    '-hide_banner',
                    '-loglevel', 'error',
                    '-f', 'pulse',
                    '-i', audio_if,
                    '-t', '00:10:00',
                    recording_dir / 'audio.mp3'
                ])

                video_process = subprocess.Popen([
                    'ffmpeg',
                    '-y', # force overwrite
                    '-hide_banner',
                    '-loglevel', 'error',
                    '-f', 'v4l2',
                    '-i', video_if,
                    '-t', '00:10:00',
                    recording_dir / 'video.mp4'
                ])

            if command == env('REBOOT_COMMAND'):
                stop(audio_process)
                stop(video_process)

                audio_process = None
                video_process = None

            if command == env('SEND_COMMAND') and recording_dir:
                stop(audio_process)
                stop(video_process)

                audio_process = None
                video_process = None

                # conversion and sending happen in the worker thread
                jobs.put(recording_dir)
                recording_dir = None
