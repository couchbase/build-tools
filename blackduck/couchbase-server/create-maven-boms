#!/usr/bin/env python3

import argparse
from collections import defaultdict
import csv
import logging
from pathlib import Path
import sys
from xml.dom import minidom

logger = logging.getLogger('blackduck/convert-gavlist-to-poms')
# Set to explicit level or else it will delegate up to the root!
logger.setLevel(logging.DEBUG)

loghandler = logging.StreamHandler()
# This is the default loglevel for the program (override with --debug)
loghandler.setLevel(logging.WARNING)
logger.addHandler(loghandler)

MAVEN_XMLNS = "http://maven.apache.org/POM/4.0.0"
XSI_XMLNS = "http://www.w3.org/2001/XMLSchema-instance"
MAVEN_SCHEMALOCATION = "http://maven.apache.org/POM/4.0.0 http://maven.apache.org/maven-v4_0_0.xsd"

class Pom:
    """
    Represents a POM and can write itself as XML
    """

    def __init__(self):
        """
        Creates the main shell of the POM document, with no <dependency>
        elements
        """

        logger.debug("Creating new pom")
        self.doc = minidom.getDOMImplementation().createDocument(
            MAVEN_XMLNS, "project", None
        )
        self.root = self.doc.documentElement

        # Add on all the pom boilerplate
        self.root.setAttribute("xmlns:xsi", XSI_XMLNS)
        self.root.setAttribute("xsi:schemaLocation", MAVEN_SCHEMALOCATION)
        self._addChildElement(self.root, "modelVersion", "4.0.0")
        self._addChildElement(self.root, "groupId", "com.couchbase.analytics")
        self._addChildElement(self.root, "artifactId", "cbas-pom")
        self._addChildElement(self.root, "version", "1.0.0-SNAPSHOT")
        self._addChildElement(self.root, "packaging", "pom")
        self.dependencies = self._addChildElement(self.root, "dependencies", None)

    def _addChildElement(self, parent, tagname, text):
        """
        Creates a new Element with given tagname (presumed to be in the
        maven xmls) with specified text content, and adds it to parent.
        If text is None, no text node will be created. Returns the new
        Element.
        """

        elem = self.doc.createElementNS(MAVEN_XMLNS, tagname)
        if text is not None:
            elem.appendChild(self.doc.createTextNode(text))
        parent.appendChild(elem)
        return elem

    def addDependency(self, group, artifact, version):
        """
        Adds a new <dependency> element to the pom's <dependencies>, including a
        "exclude all transitive dependencies" block
        """

        logger.debug(f"Adding {group} {artifact} {version} to pom")
        deps = self._addChildElement(self.dependencies, "dependency", None)
        self._addChildElement(deps, "groupId", group)
        self._addChildElement(deps, "artifactId", artifact)
        self._addChildElement(deps, "version", version)
        exclusions = self._addChildElement(deps, "exclusions", None)
        exclusion = self._addChildElement(exclusions, "exclusion", None)
        self._addChildElement(exclusion, "groupId", "*")
        self._addChildElement(exclusion, "artifactId", "*")

    def write(self, outdir):
        """
        Writes the pom as a standard pom.xml in outdir
        """

        pomfile = outdir / "pom.xml"
        logger.debug(f"Saving pom to {pomfile}")
        with pomfile.open('w') as pom:
            self.doc.writexml(pom, addindent='  ', newl='\n', encoding='UTF-8')

class GAVtoPom:
    def __init__(self, gavlist, outdir):
        """
        Opens gavlist and initializes outdir
        """

        self.outdir = outdir
        self.gavlist = csv.reader(gavlist, delimiter=':')
        self.groups = defaultdict(lambda: defaultdict(set))
        self.poms = defaultdict(lambda: Pom())

    def _create_data_struct(self):
        """
        Reads GAV list and converts into self.groups, which is a dict with
        "group" as keys. Values are dicts with "artifact" as keys, and
        a set of "versions" as values.
        """

        for (group, artifact, version) in self.gavlist:
            self.groups[group][artifact].add(version)

    def _create_poms(self):
        """
        Creates POMs in-memory such that each POM has no more than one version
        for any group:artifact. self.poms is keyed by unique integers.
        """

        for group, artifacts in self.groups.items():
            for artifact, versions in artifacts.items():
                for count, version in enumerate(versions):
                    self.poms[count].addDependency(group, artifact, version)

    def _write_poms(self):
        """
        Creates pom.xml files on disk in subdirectories of outdir
        """

        for key, pom in self.poms.items():
            # "key" is an int, which pathlib doesn't like, so string-ify it
            pomdir = self.outdir / f"{key}"
            pomdir.mkdir(exist_ok=True)
            pom.write(pomdir)

    def execute(self):
        """
        Processes GAV list into set of poms
        """

        self._create_data_struct()
        self._create_poms()
        self._write_poms()

parser = argparse.ArgumentParser(
    description='Convert GAV list to set of poms'
)
parser.add_argument('--file', '-f', dest='gavlist', required=True,
                    type=argparse.FileType(),
                    help='File containing GAV list')
parser.add_argument('--outdir', '-d', default='.',
                    help='Directory in which to create subdirs for poms')
parser.add_argument('--debug', action="store_true",
                    help='Enable debug output')
args = parser.parse_args()

outdir = Path(args.outdir)
if not outdir.exists():
    logger.error(f"Output directory '{outdir}' does not exist")
    sys.exit(1)
if args.debug:
    loghandler.setLevel(logging.DEBUG)

proc = GAVtoPom(args.gavlist, outdir)
proc.execute()
