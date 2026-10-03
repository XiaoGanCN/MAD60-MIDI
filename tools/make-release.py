#!/usr/bin/env python3
"""Creates the GitHub release for MagMIDI and uploads the app zip.

Usage: make-release.py <token> <tag> <title> <notes-file> <asset-path>
"""
import json
import os
import sys
import urllib.error
import urllib.request

REPO = "XiaoGanCN/MAD60-MIDI"


def api(url, token, payload=None, data=None, content_type="application/json", method="POST"):
    headers = {
        "Authorization": "token " + token,
        "Accept": "application/vnd.github+json",
    }
    if content_type:
        headers["Content-Type"] = content_type
    body = data if data is not None else json.dumps(payload).encode()
    request = urllib.request.Request(url, data=body, headers=headers, method=method)
    with urllib.request.urlopen(request, timeout=600) as response:
        return json.load(response)


def main():
    token, tag, title, notes_file, asset = sys.argv[1:6]
    with open(notes_file, encoding="utf-8") as handle:
        notes = handle.read()

    # Reuse the release if it already exists (idempotent re-runs).
    release = None
    try:
        release = api(f"https://api.github.com/repos/{REPO}/releases/tags/{tag}", token, method="GET")
        print("release already exists:", release["html_url"])
    except urllib.error.HTTPError as error:
        if error.code != 404:
            raise

    if release is None:
        release = api(
            f"https://api.github.com/repos/{REPO}/releases",
            token,
            {"tag_name": tag, "name": title, "body": notes, "draft": False, "prerelease": False},
        )
        print("release created:", release["html_url"])

    release_id = release["id"]
    name = os.path.basename(asset)
    with open(asset, "rb") as handle:
        blob = handle.read()

    upload_url = (
        f"https://uploads.github.com/repos/{REPO}/releases/{release_id}/assets?name={name}"
    )
    try:
        uploaded = api(upload_url, token, data=blob, content_type="application/zip")
        print("asset uploaded:", uploaded["name"], uploaded["size"], "bytes")
        print("download:", uploaded["browser_download_url"])
    except urllib.error.HTTPError as error:
        text = error.read().decode()[:400]
        if "already_exists" in text:
            print("asset already present, skipping upload")
        else:
            print("upload failed:", error.code, text)
            sys.exit(1)

    print("release page:", release["html_url"])


if __name__ == "__main__":
    main()
