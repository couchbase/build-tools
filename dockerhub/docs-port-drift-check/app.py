#!/usr/bin/env python3

# The purpose of this script is to ensure the run commands on our docker hub
# page are always up to date with the full list of client-to-node ports from
# our documentation (minus the eventing debug port - see footnote on docs url)

import re
import requests
import sys
from bs4 import BeautifulSoup

urls = {
    "docs": "https://docs.couchbase.com/server/current/install/install-ports.html",
    "hub": "https://raw.githubusercontent.com/docker-library/docs/master/couchbase/content.md",
}

# Scrape docs page, retrieving list of client-to-node ports
docs_page = requests.get(urls["docs"], allow_redirects=True).content
soup = BeautifulSoup(docs_page, features="html.parser")
for tr in soup.find_all('tr')[2:]:
    tds = tr.find_all('td')
    if tds and tds[0].text == "Client-to-node":
        _ports = [port.strip(",").strip("\n") for port in re.findall( r'([0-9\-]+[^ \]])', tds[1].text) if port != '9140']
        client_node_ports = [f'-p {port}:{port}' for port in _ports]

# Walk hub content, identifying ports listed in relevant docker run cmds
hub_page = str(requests.get(urls["hub"], allow_redirects=True).content)
hub_commands = {
    "current": [ line for line in hub_page.split("\\n") if line.startswith("`docker run") ],
    "proposed": [],
}

# Strip ports from existing run commands, and construct replacements using list
# of ports scraped from docs
for command in hub_commands["current"]:
    command = re.sub(r'(-p [0-9\-:]+ )', '', command)
    hub_commands["proposed"].append(command.replace('--name db', f'--name db {" ".join(client_node_ports)}'))

# Identify and output changes (if any)
changes = []
for i, command in enumerate(hub_commands["current"]):
    if command != hub_commands["proposed"][i]:
        changes.append({"before": command, "after": hub_commands['proposed'][i]})

if changes:
    print("Changes detected:")
    for change in changes:
        print(f"- {change['before']}")
        print(f"+ {change['after']}")
    sys.exit(1)
else:
    print("No changes detected")
