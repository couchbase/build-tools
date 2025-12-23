#!/usr/bin/env python3

import argparse
import xml.etree.ElementTree as ET
import sys


def remove_dependencies(pom_file, dep_type, value):
    """
    Remove dependencies from a maven POM file.

    Args:
        pom_file: Path to the POM file
        dep_type: "scope" or "module"
        value: scope or module value
               module is in the form of groupId:artifactId
    """

    # Maven POM namespace
    ns = {"m": "http://maven.apache.org/POM/4.0.0"}
    ET.register_namespace("", ns["m"])
    tree = ET.parse(pom_file)
    root = tree.getroot()

    # Find all dependencies sections
    for deps in root.findall(".//m:dependencies", ns):
        for dep in list(deps.findall("m:dependency", ns)):
            should_remove = False

            if dep_type == "scope":
                scope = dep.find("m:scope", ns)
                if scope is not None and scope.text.strip() == value:
                    should_remove = True
            elif dep_type == "module":
                group_id, artifact_id = value.split(":")
                group_id_elem = dep.find("m:groupId", ns)
                artifact_id_elem = dep.find("m:artifactId", ns)
                if (group_id_elem is not None and artifact_id_elem is not None and
                    group_id_elem.text.strip() == group_id and
                        artifact_id_elem.text.strip() == artifact_id):
                    should_remove = True

            if should_remove:
                deps.remove(dep)

    # Write cleaned POM back
    tree.write(pom_file, encoding="utf-8", xml_declaration=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description="Remove dependencies from a maven POM file")
    parser.add_argument(
        "-p",
        "--pom_file",
        help="Path to the maven POM file",
        default="pom.xml")
    parser.add_argument("-s", "--scope", type=str, help="Scope to remove")
    parser.add_argument("-m", "--module", type=str, help="Module to remove")
    args = parser.parse_args()
    if args.scope is not None and args.module is not None:
        print("Error: --scope and --module cannot be used together")
        sys.exit(1)

    pom_file = args.pom_file
    if args.scope is not None:
        remove_dependencies(pom_file, "scope", args.scope)
    elif args.module is not None:
        remove_dependencies(pom_file, "module", args.module)
