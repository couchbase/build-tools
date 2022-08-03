#!/usr/bin/env python3

# The purpose of this script is to ensure the run commands on our docker hub
# page as well as the EXPOSED ports and io.openshift.ports label in our
# dockerfiles are kept up to date with the full list of client-to-node ports
# from our documentation (minus the eventing debug port - see footnote on docs
# url)

import re
import requests
import sys
from bs4 import BeautifulSoup

urls = {
    "docs_port_list": "https://docs.couchbase.com/server/current/install/install-ports.html",
    "dockerhub_readme": "https://raw.githubusercontent.com/docker-library/docs/master/couchbase/content.md",
    "dockerhub_dockerfile": "https://raw.githubusercontent.com/couchbase/docker/master/generate/templates/couchbase-server/Dockerfile.template",
    "redhat_dockerfile": "https://raw.githubusercontent.com/couchbase-partners/redhat-openshift/master/couchbase-server/Dockerfile",
}

class Docs():
    def __init__(self):
        self.page = None
        self.client_to_node_column = None
        self.client_to_node_ports = None
        self.port_map = None
        self.get_client_to_node_column()

    def get_page(self):
        if not self.page:
            docs_page = requests.get(
                urls["docs_port_list"], allow_redirects=True).content
            self.page = BeautifulSoup(docs_page, features="html.parser")
        return self.page

    def get_table(self, table_id):
        return self.get_page().find('table', id=table_id)

    def get_client_to_node_column(self):
        # Find the column index in our table for client-to-node ports
        if not self.client_to_node_column:
            for thead in self.get_table('table-ports-detailed').find_all('thead'):
                ths = thead.find_all('th')
                for i, th in enumerate(ths):
                    if th.text == "Client-to-node":
                        self.client_to_node_column = i
        return self.client_to_node_column

    def ports(self):
        # Retrieve list of ports and their functions
        if not self.client_to_node_ports:
            self.client_to_node_ports = {}
            for tr in self.get_table('table-ports-detailed').find_all('tr')[2:]:
                tds = tr.find_all('td')
                if tds and tds[1].text:
                    if tds[self.get_client_to_node_column()].text.lower() == 'yes':
                        unencrypted = encrypted = None
                        if not re.match("[0-9 /]+", tds[1].text):
                            continue
                        if " / " in tds[1].text:
                            (unencrypted, encrypted) = tds[1].text.split(' / ')
                            self.client_to_node_ports[int(unencrypted)] = tds[0].text.split(
                                ' / ')[0].replace("_port", "")
                            self.client_to_node_ports[int(encrypted)] = tds[0].text.split(
                                ' / ')[1].replace("_port", "")
                        elif tds[1].text != '9140':
                            self.client_to_node_ports[int(
                                tds[1].text)] = tds[0].text.replace("_port", "")
        return self.client_to_node_ports

    def docker_run_port_mappings(self):
        # Generate list of docker run port mappings
        if not self.port_map:
            self.port_map = []
            range_start = None
            previous_port = None
            sorted_ports = sorted(self.ports())
            for i, port in enumerate(sorted_ports):
                if not previous_port or not range_start:
                    range_start = port
                elif port - previous_port == 1:
                    range_cursor = port
                    if i == len(sorted_ports)-1:
                        self.port_map.append(
                            f'-p {range_start}-{range_cursor}:{range_start}-{range_cursor}')
                else:
                    if range_cursor or i == len(sorted_ports)-1:
                        self.port_map.append(
                            f'-p {range_start}-{range_cursor}:{range_start}-{range_cursor}')
                    else:
                        self.port_map.append(f'-p {range_start}:{range_start}')
                    range_cursor = None
                    range_start = port
                previous_port = port
        return self.port_map


class Readme():
    def __init__(self, docs):
        self.docs = docs
        self.hub_commands = None
        self.changes = []
        pass

    def get_current_commands(self):
        # Walk hub content, identifying ports listed in relevant docker run cmds
        if not self.hub_commands:
            hub_page = str(requests.get(
                urls["dockerhub_readme"], allow_redirects=True).content)
            self.hub_commands = {
                "current": [line for line in hub_page.split("\\n") if line.startswith("`docker run")],
                "proposed": [],
            }
        return self.hub_commands

    def get_proposed_commands(self):
        # Strip ports from existing run commands and construct replacements using list
        # of ports scraped from docs
        if not self.hub_commands:
            self.get_current_commands()
            self.hub_commands["proposed"] = []
            for command in self.hub_commands["current"]:
                command = re.sub(r'(-p [0-9\-:]+ )', '', command)
                self.hub_commands["proposed"].append(command.replace(
                    '--name db', f'--name db {" ".join(self.docs.docker_run_port_mappings())}'))
        return self.hub_commands

    def identify_changes(self):
        # Identify readme changes required
        if not self.changes:
            self.get_proposed_commands()
            for i, command in enumerate(self.hub_commands["current"]):
                if command != self.hub_commands["proposed"][i]:
                    self.changes.append(
                        {"before": command, "after": self.hub_commands['proposed'][i]})
        return self.changes

    def changes_needed(self):
        # Check if any changes needed and output details
        self.identify_changes()
        if self.changes:
            print("dockerhub description needs changes:")
            for change in self.changes:
                print(f"    - {change['before']}")
                print(f"    + {change['after']}")
                print()
            return True
        else:
            print("dockerhub description doesn't need any changes")
            print()
            return False


class Dockerfile():
    def __init__(self, docs, host):
        self.docs = docs
        self.host = host
        self.ports = docs.ports()
        self.dockerfile_lines = str(requests.get(
            urls[f"{host}_dockerfile"], allow_redirects=True).content).split("\\n")
        self.dockerfile_lines = [x.strip() for x in self.dockerfile_lines]
        self.get_exposed_ports()

    def get_exposed_ports(self):
        # Get a list of ports EXPOSEd in the dockerfile
        capturing = False
        self.exposed_ports = []
        for line in self.dockerfile_lines:
            if line.startswith('EXPOSE') or capturing:
                capturing = True
                self.exposed_ports += (re.findall("[0-9]+", line))
                if not line.endswith("\\"):
                    capturing = False
                    break
        self.exposed_ports = [int(x) for x in self.exposed_ports]
        return self.exposed_ports

    def exposed_ports_changes_needed(self):
        # Check if any EXPOSE changes are required and output if so
        missing_ports = []
        extra_ports = []
        for port in self.ports.keys():
            if port not in self.get_exposed_ports():
                missing_ports.append(str(port))
        for port in self.get_exposed_ports():
            if port not in self.ports.keys():
                extra_ports.append(str(port))
        if missing_ports or extra_ports:
            print(f"{self.host} needs EXPOSE changes:")
            print("    + ", ", ".join(sorted(missing_ports)))
            print("    - ", ", ".join(sorted(extra_ports)))
            print()
            return True
        else:
            print(f"{self.host} EXPOSE section is OK")
            print()
            return False

    def openshift_expose_changes_needed(self):
        # (Redhat only) check io.openshift.expose-services LABEL is up to date
        # and output any necessary changes
        expose_list = ",".join(
            [f"{str(x)}/tcp:{self.docs.ports()[x]}" for x in sorted(self.docs.ports())])
        expose_line = f'io.openshift.expose-services="{expose_list}"'
        for line in self.dockerfile_lines:
            found_line = re.search(
                "^(LABEL)*[\s]*io.openshift.expose-services=\"(.*)\"", line)
            if found_line:
                break
        if not found_line:
            print(f"{self.host} has no io.openshift.expose-services label, needs:")
            print(f"    + {expose_line}")
            print()
            return True
        else:
            if found_line.string.replace('LABEL', '').strip() != expose_line:
                print(
                    f"{self.host} Dockerfile has incorrect io.openshift.expose-services label:")
                print(
                    f"    - {found_line.string.replace('LABEL', '').strip()}")
                print(f"    + io.openshift.expose-services=\"{expose_list}\"")
                print()
                return True
            else:
                print(f"{self.host} io.openshift.expose-services label is OK")
                print()
                return False


if __name__ == '__main__':
    docs = Docs()
    readme = Readme(docs)
    dockerhub = Dockerfile(docs, "dockerhub")
    redhat = Dockerfile(docs, "redhat")
    sys.exit(any([
        dockerhub.exposed_ports_changes_needed(),
        redhat.exposed_ports_changes_needed(),
        redhat.openshift_expose_changes_needed(),
        readme.changes_needed()]))
