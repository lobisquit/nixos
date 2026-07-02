import json
import logging as log
import os
import subprocess
import sys
import time
from contextlib import contextmanager
from pathlib import Path

import feedparser
import requests
from feedgen.feed import FeedGenerator
from selenium import webdriver
from selenium.common.exceptions import NoSuchElementException, TimeoutException
from selenium.webdriver.common.action_chains import ActionChains
from selenium.webdriver.common.by import By
from selenium.webdriver.common.keys import Keys
from selenium.webdriver.firefox.service import Service
from selenium.webdriver.support import expected_conditions as EC
from selenium.webdriver.support.ui import WebDriverWait

log_level = os.environ.get('LOG_LEVEL', log.INFO)
log.basicConfig(level=log_level,
                format="[%(funcName)s] %(message)s",
                handlers=[log.StreamHandler()])


class IlPostScraper:
    def __init__(self, firefox_path, geckdriver_path, username, password, timeout_s=10):
        self.timeout_s = timeout_s
        self.firefox_path = firefox_path
        self.geckdriver_path = geckdriver_path
        self.username = username
        self.password = password

        self.logged_in = False

    def __enter__(self):
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

    def wait_for_correct_current_url(self, desired_url):
        self.wait.until(
            lambda driver: \
            driver.current_url == desired_url or \
            driver.current_url == desired_url + "/"
        )

    def is_present(self, query):
        try:
            element = self.driver.find_element(*query)
            return True
        except NoSuchElementException:
            return False

    def reject_cookies_if_any(self):
        while self.is_present((By.CLASS_NAME, "iubenda-cs-reject-btn")):
            self.click_when_ready((By.CLASS_NAME, "iubenda-cs-reject-btn"))

    def login(self):
        log.info("Started login")
        login_url = 'https://www.ilpost.it/wp-login.php'
        self.driver.get(login_url)

        self.get_when_ready((By.ID, "user_login")).send_keys(self.username)
        self.get_when_ready((By.ID, "user_pass")).send_keys(self.password)

        self.reject_cookies_if_any() # could spawn at any time
        self.click_when_ready((By.ID, "wp-submit"))

        self.wait_for_correct_current_url("https://abbonati.ilpost.it/mio-account")

        self.logged_in = True
        log.info("Ended login")

    def get_audio_info(self, episode_url):
        if not self.logged_in:
            self.login()

        if self.driver.current_url != episode_url:
            self.driver.get(episode_url)

        self.reject_cookies_if_any() # could spawn at any time

        # get audio element mp3 url
        audio_url = self.get_when_ready((By.TAG_NAME, "audio")) \
                        .get_attribute("src")

        # get size (needed by spec compliant RSS feeds), falling back
        # to zero if anything is bad
        with requests.get(audio_url, stream=True) as resp:
            audio_size_byte = resp.headers.get('Content-Length', '0')

        return audio_url, audio_size_byte

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

    with IlPostScraper(os.environ['FIREFOX'],
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

                # Fetch audio url of the episode if not present
                audio_info_path = Path(feed_label) / (Path(episode_url).stem + '.txt')
                audio_info_path.parent.mkdir(parents=True, exist_ok=True)

                if not Path(audio_info_path).is_file():
                    log.info(f'Getting audio url of {episode_url}')
                    audio_url, audio_size_byte = scraper.get_audio_info(episode_url)
                    audio_info = {'url': audio_url, 'size_byte': audio_size_byte}

                    with open(audio_info_path, 'w') as f:
                        json.dump(audio_info, f)
                else:
                    log.info(f'Already found "{audio_info_path}"')

                    with open(audio_info_path, 'r') as f:
                        audio_info = json.load(f)

                # Fetch or read description of the episode
                description_path = Path(feed_label) / (Path(episode_url).stem + '.html')
                description_path.parent.mkdir(parents=True, exist_ok=True)

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
                fe.enclosure(audio_info['url'], audio_info['size_byte'], 'audio/mpeg')
                fe.pubDate(entry.published)

            fg.rss_file(Path(feed_label) / 'feed.xml')
