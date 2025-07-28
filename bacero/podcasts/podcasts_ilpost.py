import json
import logging as log
import os
import subprocess
import sys
import time
from contextlib import contextmanager
from pathlib import Path

import feedparser
import pulsectl
from feedgen.feed import FeedGenerator
from selenium import webdriver
from selenium.webdriver.common.action_chains import ActionChains
from selenium.webdriver.common.by import By
from selenium.webdriver.common.keys import Keys
from selenium.webdriver.firefox.service import Service
from selenium.webdriver.support import expected_conditions as EC
from selenium.webdriver.support.ui import WebDriverWait
from selenium.common.exceptions import TimeoutException

log_level = os.environ.get('LOG_LEVEL', log.INFO)
log.basicConfig(level=log_level,
                format="[%(funcName)s] %(message)s",
                handlers=[log.StreamHandler()])


@contextmanager
def null_sink(sink_name):
    with pulsectl.Pulse('ilpost_scraper') as pulse:
        sink_id = None
        current_sinks = {s.name: s for s in pulse.sink_list()}

        if sink_name not in current_sinks:
            sink_id = pulse.module_load('module-null-sink', f'sink_name={sink_name}')
        else:
            log.warning(f"PA sink {sink_name} already exists")
            sink_id = current_sinks[sink_name].owner_module

        try:
            log.info("Sink enabled")
            yield sink_name
        finally:
            pulse.module_unload(sink_id)
            log.info("Sink unloaded")


@contextmanager
def recorder(audio_interface, episode_path):
    Path(episode_path).parent.mkdir(parents=True, exist_ok=True)
    recorder = subprocess.Popen([
        'ffmpeg', '-hide_banner', '-loglevel', 'error', '-f', 'pulse',
        '-i', f'{audio_interface}.monitor', episode_path
    ])

    try:
        log.info("Started recording")
        yield recorder
    finally:
        recorder.terminate()
        recorder.wait()
        log.info("Stopped recording")


class IlPostScraper:
    def __init__(self, sink_name, firefox_path, geckdriver_path, username, password, timeout_s=10):
        self.sink_name = sink_name
        self.timeout_s = timeout_s
        self.firefox_path = firefox_path
        self.geckdriver_path = geckdriver_path
        self.username = username
        self.password = password

        self.logged_in = False

    def __enter__(self):
        os.environ['PULSE_SINK'] = self.sink_name

        service = Service(
            executable_path=self.geckdriver_path,
            # log_output="/tmp/selenium_browser.log",
            # service_args=['--log-no-truncate', '--log', 'debug']
        )

        options = webdriver.FirefoxOptions()
        options.binary_location = self.firefox_path

        if not os.environ.get('DEBUG', None):
            options.add_argument("--headless")

        self.driver = webdriver.Firefox(options=options,
                                        service=service)

        self.wait = WebDriverWait(self.driver, self.timeout_s)
        log.info("Selenium browser started")

        return self

    def __exit__(self, type, value, tb):
        self.driver.close()
        log.info("Selenium browser closed")

    def click_when_ready(self, query):
        elem = self.wait.until(EC.element_to_be_clickable((query)))
        elem.click()
        return elem

    def get_when_ready(self, query):
        elem = self.wait.until(EC.presence_of_element_located((query)))
        return elem

    def login(self):
        log.info("Started login")
        login_url = 'https://www.ilpost.it/wp-login.php'
        self.driver.get(login_url)

        self.get_when_ready((By.ID, "user_login")).send_keys(self.username)
        self.get_when_ready((By.ID, "user_pass")).send_keys(self.password)
        self.click_when_ready((By.ID, "wp-submit"))

        # reject cookies
        self.click_when_ready((By.CLASS_NAME, "iubenda-cs-reject-btn"))

        self.logged_in = True
        log.info("Ended login")

    def download_episode(self, episode_url, episode_path):
        if not self.logged_in:
            self.login()

        if self.driver.current_url != episode_url:
            self.driver.get(episode_url)

        progress_bar = self.wait.until(
            EC.element_to_be_clickable((By.XPATH, "//progress")))

        log.info("Waiting for progress bar size to stabilize")
        initial_size = progress_bar.size
        self.wait.until(lambda d: progress_bar.size == initial_size)
        log.info("Progress bar size stabilized {} == {}".format(
                 initial_size['width'],
                 progress_bar.size['width']))

        ActionChains(self.driver) \
            .move_to_element(progress_bar) \
            .move_by_offset(-progress_bar.size['width'] / 2, 0) \
            .click() \
            .perform()

        with recorder(sink_name, episode_path):
            log.info("Waiting for the play button")
            self.click_when_ready((By.CSS_SELECTOR, '[aria-label=Play]'))
            log.info("Play button clicked")

            while float(progress_bar.get_attribute('value')) < \
                  float(progress_bar.get_attribute('max')):
                progress_value = float(progress_bar.get_attribute('value'))
                max_value = float(progress_bar.get_attribute('max'))

                # print current time at the beginning and at the end of the recording
                delta = 10
                if progress_value < delta or progress_value > max_value - delta:
                    log.info(f'{progress_value} {max_value}')

                time.sleep(1)

    def get_description(self, episode_url):
        if not self.logged_in:
            self.login()

        if self.driver.current_url != episode_url:
            self.driver.get(episode_url)

        try:
            episode_description = self.get_when_ready((By.ID, "singleBody"))
            return episode_description.get_attribute('innerHTML')
        # description can be missing in some of the episodes
        except TimeoutException:
            return " "


def read_conf(conf_path):
    with open(conf_path, 'r') as f:
        confs = json.load(f)

    for conf in confs:
        yield conf


if __name__ == '__main__':
    confs = read_conf(sys.argv[1])

    base_url = Path(os.environ['BASE_URL'])
    username = os.environ['USERNAME']
    password = os.environ['PASSWORD']

    with null_sink("virtualsink") as sink_name, \
         IlPostScraper(sink_name,
                       os.environ['FIREFOX'],
                       os.environ['GECKODRIVER'],
                       os.environ['USERNAME'],
                       os.environ['PASSWORD']) as scraper:
        for conf in confs:
            log.info(str(conf))

            feed_label = conf['label']
            feed_url = conf['feed_url']
            logo_url = conf['logo_url']
            feed = feedparser.parse(feed_url)

            if feed.bozo:
                log.warning("Feed is bozo")

            fg = FeedGenerator()
            fg.id(feed.feed.link)
            fg.title(feed.feed.title)
            fg.link(href=feed.feed.link, rel='alternate')
            fg.logo(logo_url)
            fg.subtitle(feed.feed.subtitle)
            fg.language(feed.feed.language)
            fg.updated(feed.updated)

            for entry in feed.entries:
                episode_url = entry.link
                episode_path = Path(feed_label) / (Path(episode_url).stem + '.mp3')
                description_path = Path(feed_label) / (Path(episode_url).stem + '.html')

                if not Path(episode_path).is_file():
                    log.info(f'Downloading {episode_path}')
                    scraper.download_episode(episode_url, episode_path)
                else:
                    log.info(f'Already found "{episode_path}"')

                if not Path(description_path).is_file():
                    log.info(f"Getting description of {episode_url}")

                    episode_description = scraper.get_description(episode_url)
                    with open(description_path, 'w') as f:
                        f.write(episode_description)
                else:
                    log.info(f'Already found description of "{episode_url}"')

                    with open(description_path, 'r') as f:
                        episode_description = f.read()

                fe = fg.add_entry()
                fe.id(entry.id)
                fe.title(entry.title)
                fe.link(entry.links[0])
                fe.description(episode_description)
                fe.enclosure("https://" + str(base_url / episode_path),
                             episode_path.stat().st_size,
                             'audio/mpeg')
                fe.pubDate(entry.published)

            fg.rss_file(Path(feed_label) / 'feed.xml')
