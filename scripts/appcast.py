"""Build Sparkle appcasts and promote existing signed release entries."""
import argparse
import base64
import copy
import datetime
import email.utils
import html
import pathlib
import re
import xml.etree.ElementTree as ET

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE)


def signature_attributes(text):
    attributes = dict(re.findall(r'([\w:]+)="([^"]*)"', text))
    if not attributes:
        attributes = dict(re.findall(r'([\w:]+)=(\S+)', text))
    signature = attributes.get("sparkle:edSignature", "")
    if len(base64.b64decode(signature, validate=True)) != 64:
        raise ValueError("Sparkle must provide a valid Ed25519 signature.")
    length = int(attributes.get("length", "0"))
    if length <= 0:
        raise ValueError("Update archive length must be positive.")
    return signature, str(length)


def read_feed(path):
    root = ET.parse(path).getroot()
    if root.tag != "rss" or root.find("channel") is None:
        raise ValueError("Invalid Sparkle RSS feed.")
    return root


def write_feed(root, path):
    ET.indent(root, space="  ")
    ET.ElementTree(root).write(path, encoding="utf-8", xml_declaration=True)


def add_release(path, version, build, url, signature, notes_url="", notes_signature="", notes_length=""):
    if not re.fullmatch(r"\d+\.\d+\.\d+", version) or not str(build).isdigit():
        raise ValueError("Invalid release version or build number.")
    if not url.startswith("https://github.com/grahamgilbert/watt/releases/download/"):
        raise ValueError("Updates must use this app's public HTTPS release assets.")
    ed_signature, length = signature_attributes(signature)
    root = read_feed(path)
    channel = root.find("channel")
    for old in list(channel.findall("item")):
        old_version = old.findtext(f"{{{SPARKLE}}}shortVersionString")
        old_build = int(old.findtext(f"{{{SPARKLE}}}version", "0"))
        if old_version == version and old_build == int(build):
            channel.remove(old)
        elif old_build >= int(build):
            raise ValueError("Increment the release build number before publishing a new update.")
    item = ET.Element("item")
    ET.SubElement(item, "title").text = "Watt " + version
    ET.SubElement(item, "pubDate").text = email.utils.format_datetime(datetime.datetime.now(datetime.timezone.utc))
    for key, value in [("version", str(build)), ("shortVersionString", version), ("minimumSystemVersion", "14.0")]:
        ET.SubElement(item, f"{{{SPARKLE}}}{key}").text = value
    ET.SubElement(item, "link").text = "https://github.com/grahamgilbert/watt/releases/tag/v" + version
    if notes_url:
        if not notes_url.startswith("https://github.com/grahamgilbert/watt/releases/download/v"+version+"/"):
            raise ValueError("Notes must use this version\'s public release assets.")
        if len(base64.b64decode(notes_signature, validate=True)) != 64 or int(notes_length) <= 0:
            raise ValueError("Release notes must be signed.")
        ET.SubElement(item, f"{{{SPARKLE}}}releaseNotesLink", {
            f"{{{SPARKLE}}}edSignature": notes_signature, f"{{{SPARKLE}}}length": str(notes_length)
        }).text = notes_url
    ET.SubElement(item, "enclosure", {"url": url, "length": length, "type": "application/octet-stream",
        f"{{{SPARKLE}}}edSignature": ed_signature})
    channel.insert(3, item)
    write_feed(root, path)


def promote(source, destination, version):
    prerelease, stable = read_feed(source), read_feed(destination)
    item = next((item for item in prerelease.findall("channel/item")
                 if item.findtext(f"{{{SPARKLE}}}shortVersionString") == version), None)
    if item is None:
        raise ValueError("Version is not present in the prerelease feed.")
    channel = stable.find("channel")
    build=int(item.findtext(f"{{{SPARKLE}}}version", "0"))
    if any(int(old.findtext(f"{{{SPARKLE}}}version", "0"))>build for old in channel.findall("item")):
        raise ValueError("Promotion must not downgrade the stable feed.")
    for existing in list(channel.findall("item")):
        if existing.findtext(f"{{{SPARKLE}}}shortVersionString") == version:
            channel.remove(existing)
    channel.insert(3, copy.deepcopy(item))
    write_feed(stable, destination)


def release_notes(markdown, version):
    # GitHub-generated notes are escaped before any markup is added.
    lines = []
    for line in markdown.splitlines():
        text = html.escape(line)
        if line.startswith("## "):
            lines.append("<h2>" + html.escape(line[3:]) + "</h2>")
        elif line.startswith("* ") or line.startswith("- "):
            lines.append("<p>• " + html.escape(line[2:]) + "</p>")
        elif line.strip():
            lines.append("<p>" + text + "</p>")
    return '<!doctype html><html><head><meta charset="utf-8"><style>body{font:14px -apple-system;padding:16px}p{line-height:1.5}</style></head><body><h1>Watt ' + html.escape(version) + "</h1>" + "\n".join(lines) + "</body></html>"


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    commands = parser.add_subparsers(dest="command", required=True)
    add = commands.add_parser("add")
    for name in ["feed", "version", "build", "url", "signature", "notes-url", "notes-signature", "notes-length"]:
        add.add_argument("--" + name, required=True)
    promotion = commands.add_parser("promote")
    for name in ["source", "destination", "version"]:
        promotion.add_argument("--" + name, required=True)
    notes = commands.add_parser("notes")
    notes.add_argument("--input", required=True)
    notes.add_argument("--output", required=True)
    notes.add_argument("--version", required=True)
    args = parser.parse_args()
    if args.command == "add":
        add_release(args.feed, args.version, args.build, args.url, args.signature, args.notes_url, args.notes_signature, args.notes_length)
    elif args.command == "promote":
        promote(args.source, args.destination, args.version)
    else:
        pathlib.Path(args.output).write_text(release_notes(pathlib.Path(args.input).read_text(), args.version))
