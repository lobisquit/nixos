import subprocess
import requests
import serial
import os
from pathlib import Path
import time

def env(name):
    return os.environ[name]


if __name__ == '__main__':
    with serial.Serial(env('SERIAL_DEV'), env('SERIAL_BAUD_RATE'), timeout=0) as ser:
        ser.setRTS(False)
        ser.setDTR(False)

        audio_process = None
        video_process = None

        # wait for the first 'b' after the reboot caused by the connection
        while ser.read(1) != b'b':
            time.sleep(0.001)

        print('Startup byte detected from board', flush=True)

        while True:
            time.sleep(0.010)

            # blocking call for next character
            next_byte = ser.read(1)
            if len(next_byte) == 0:
                continue

            command = next_byte.decode('ascii')
            print('Loaded command:', command, flush=True)

            if command == env('RECORD_COMMAND'):
                video_if = env('VIDEO_INTERFACE')
                audio_if = env('AUDIO_INTERFACE')

                print('Started recording', flush=True)
                subprocess.run(['amixer', '-M', 'set', 'Capture', '15%'])

                audio_process = subprocess.Popen([
                    'ffmpeg',
                    '-y', # force overwrite
                    '-hide_banner',
                    '-loglevel', 'error',
                    '-f', 'pulse',
                    '-i', audio_if,
                    '-t', '00:10:00',
                    Path(env('TMP_PATH')) / 'audio.mp3'
                ])

                video_process = subprocess.Popen([
                    'ffmpeg',
                    '-y', # force overwrite
                    '-hide_banner',
                    '-loglevel', 'error',
                    '-f', 'v4l2',
                    '-i', video_if,
                    '-t', '00:10:00',
                    Path(env('TMP_PATH')) / 'video.mp4'
                ])

            if command == env('REBOOT_COMMAND'):
                if recorder_process:
                    audio_process.terminate()
                    video_process.terminate()

                    audio_process.wait()
                    video_process.wait()

            if command == env('SEND_COMMAND'):
                audio_process.terminate()
                video_process.terminate()

                audio_process.wait()
                video_process.wait()

                audio_process = None
                video_process = None

                subprocess.run([
                    'ffmpeg',
                    '-y', # force overwrite
                    '-hide_banner',
                    '-loglevel', 'error',
                    '-i', Path(env('TMP_PATH')) / 'video.mp4',
                    '-i', Path(env('TMP_PATH')) / 'audio.mp3',
                    '-c:v', 'libx264',
                    '-profile:v', 'baseline',
                    '-c:a', 'aac',
                    '-ar', '44100',
                    '-ac', '2',
                    '-b:a', '128k',
                    '-vf', 'format=yuv420p',
                    Path(env('TMP_PATH')) / 'combined.mp4'])

                print('Sending recording to chats', flush=True)

                with open(Path(env('TMP_PATH')) / 'combined.mp4', 'rb') as video:
                    chats = env('TELEGRAM_CHATS').strip().split(',')
                    token = env('TELEGRAM_TOKEN').strip()

                    for chat_id in chats:
                        requests.post(
                            url=f'https://api.telegram.org/bot{token}/sendVideo',
                            data={'chat_id': chat_id},
                            files={'video': video})
