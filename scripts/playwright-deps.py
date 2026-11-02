#!/usr/bin/env python3
"""Turn `playwright install-deps --dry-run chromium` output into a checked apt package list.

The installer runs Playwright's dry run as the desktop user, then passes the names printed here
to `sudo apt-get install`. Nothing from the user-writable engine checkout or venv runs as root,
and every name must look like a Debian package, so a tampered venv can't smuggle in options or
shell syntax. Exits 1 when no package list is found.
"""
import re
import sys

PACKAGE = re.compile(r"^[a-z0-9][a-z0-9+.-]+(:[a-z0-9-]+)?$")


def packages(text):
    names = []
    for match in re.finditer(r"apt-get install\b([^\"\n&;|]*)", text):
        for token in match.group(1).split():
            if token.startswith("-"):
                continue
            if not PACKAGE.match(token):
                raise ValueError(f"unexpected package name: {token!r}")
            if token not in names:
                names.append(token)
    return names


def main():
    try:
        names = packages(sys.stdin.read())
    except ValueError as error:
        print(f"playwright-deps: {error}", file=sys.stderr)
        return 1
    if not names:
        return 1
    print(" ".join(names))
    return 0


if __name__ == "__main__":
    sys.exit(main())
