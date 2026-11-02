#!/usr/bin/env python3
"""Fill @APP_DIR@ in the nmapui.service template: render-unit.py TEMPLATE APP_DIR OUTPUT.

A literal replacement (sed broke on paths containing | & or %). systemd expands %-specifiers in
WorkingDirectory= and ExecStart=, so % is written as %%. Paths systemd would split or unquote
(whitespace, quotes, backslashes, control characters) are refused rather than half-escaped.
"""
import pathlib
import sys


def render(template, app_dir):
    if not app_dir.startswith("/"):
        raise ValueError(f"the engine path must be absolute: {app_dir!r}")
    if any(ord(c) < 32 or c.isspace() or c in "\"'\\" for c in app_dir):
        raise ValueError(f"the engine path can't contain spaces, quotes or backslashes: {app_dir!r}; "
                         "set NMAPUI_APP_DIR to another folder")
    return template.replace("@APP_DIR@", app_dir.replace("%", "%%"))


def main(argv):
    if len(argv) != 4:
        print(__doc__, file=sys.stderr)
        return 2
    try:
        text = render(pathlib.Path(argv[1]).read_text(), argv[2])
    except ValueError as error:
        print(f"install-backend: {error}", file=sys.stderr)
        return 1
    pathlib.Path(argv[3]).write_text(text)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
