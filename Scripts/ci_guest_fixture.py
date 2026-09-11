#!/usr/bin/env python3
import os
from pathlib import Path


MARKER = "CI_ONLY_NOT_A_GUEST.txt"
MESSAGE = """This directory is a CI build fixture, not an Omarchy installation.
It contains no kernel, disk image, or guest manifest.
Never distribute an app containing this file.
Prepare the real guest in a clean workspace before archiving Omabox.
"""


def create_fixture(directory: Path) -> None:
    if os.environ.get("CI") != "true" or os.environ.get("GITHUB_ACTIONS") != "true":
        raise RuntimeError("The empty guest fixture is restricted to GitHub Actions CI.")
    try:
        directory.mkdir()
    except FileExistsError as error:
        raise RuntimeError(f"Refusing to replace an existing guest directory: {directory}") from error
    with (directory / MARKER).open("x") as marker:
        marker.write(MESSAGE)


def main() -> None:
    directory = Path(__file__).resolve().parents[1] / "Omabox/Resources/Guest"
    create_fixture(directory)
    print("Created a CI-only resource fixture. This app cannot run a guest or be distributed.")


if __name__ == "__main__":
    main()
