import feedparser
import subprocess
import os
from pathlib import Path
import sys
from feedgen.feed import FeedGenerator
import logging as log
import urllib.request
import json

log_level = os.environ.get('LOG_LEVEL', log.INFO)
log.basicConfig(level=log_level,
                format="[%(funcName)s] %(message)s",
                handlers=[log.StreamHandler()])


def read_conf(conf_path):
    with open(conf_path, 'r') as f:
        confs = json.load(f)

    for conf in confs:
        yield conf


def get_url_of_type(links, type_):
    for link in links:
        if link.type == type_:
            return link


if __name__ == '__main__':
    confs = read_conf(sys.argv[1])

    base_url = Path(os.environ['BASE_URL'])

    for conf in confs:
        log.info(str(conf))

        feed_label = conf['label']
        feed_url = conf['feed_url']
        feed = feedparser.parse(feed_url)

        fg = FeedGenerator()
        fg.id(feed.feed.link)
        fg.title(feed.feed.title)
        fg.link(href=feed.feed.link, rel='alternate')
        fg.subtitle(' ')
        fg.language('it')
        fg.logo(feed.feed.image.href)
        fg.updated(feed.feed.updated)

        for entry in feed.entries[:5]:
            episode_path = Path(feed_label) / (Path(entry.id).stem + '.mp3')

            if Path(episode_path).is_file():
                log.info(f'Already found "{episode_path}"')
            else:
                log.info(f'Downloading {episode_path}')

                Path(episode_path).parent.mkdir(parents=True,
                                                exist_ok=True)

                media_file_url = get_url_of_type(entry.links, 'audio/mpeg').href
                urllib.request.urlretrieve(media_file_url, episode_path)

            fe = fg.add_entry()
            fe.id(entry.id)
            fe.title(entry.title)

            web_page_url = get_url_of_type(entry.links, 'text/html')
            fe.link(web_page_url)

            fe.description(entry.description)
            fe.enclosure("https://" + str(base_url / episode_path),
                         episode_path.stat().st_size,
                         'audio/mpeg')
            fe.pubDate(entry.published)

        fg.rss_file(Path(feed_label) / 'feed.xml')
