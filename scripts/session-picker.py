#!/usr/bin/env python3
"""Rex session picker, like sesh for tmux. Opened in a floating layer by
the pick_repo_session and toggle_session actions in
lua/rex_sessions/init.lua.

  session-picker.py                               pick a session or dir
  session-picker.py open SERVER LABEL [DIR]       switch, creating in DIR
  session-picker.py mode MODE                     remember MODE, print its prompt
  session-picker.py home                          remember the home mode
  session-picker.py next-server                   remember the next remote
  session-picker.py probe-remotes                 find the remotes that answer
  session-picker.py current                       list the remembered mode
  session-picker.py pin SERVER LABEL DIR ID       pin or unpin LABEL
  session-picker.py move-pin SERVER LABEL ID up|down
  session-picker.py kill SERVER ID                close a session
  session-picker.py preview SERVER KIND LABEL DIR ID

SERVER is a Rex host label, or "" for the server running this picker.
Rows are tab-separated: server, kind (session|dir), label, dir, session
id, display text (see session-list.lua).

MODE is local (the server running this picker, i.e. the session's),
remote:SERVER, or zoxide (when installed). The home mode is the server
on the machine you're using, which differs from local in a remote
session, and the remotes are the others; alt-r offers those that
answer. The picker starts in local, or in home when REX_PICKER_START is
"home" (see start_server in lua/rex_sessions/init.lua).
REX_PICKER_CLIENT is the label of the app that opened the picker, found
from REX_PICKER_CLIENT_ID (see servers.lua).

Pins live on the server whose sessions they are (see the pin actions in
lua/rex_sessions/init.lua), so every picker shows the same ones.

REX_PICKER_PREVIEW holds the commands that preview a directory, one per
line (see `preview` in lua/rex_sessions/init.lua).

Needs fzf. Uses zoxide (alt-z) when installed. Standard library only,
and Python 3.9 compatible for macOS's /usr/bin/python3.
"""

from __future__ import annotations

import json
import os
import shlex
import shutil
import socket
import subprocess
import sys
import tempfile
from pathlib import Path

SCRIPT = Path(__file__).resolve()
SELF = f"{shlex.quote(sys.executable)} {shlex.quote(str(SCRIPT))}"
HOME = str(Path.home())
DEVNULL = subprocess.DEVNULL
HAS_ZOXIDE = shutil.which("zoxide") is not None


def env(name: str) -> str:
    return os.environ.get(name, "")


def state(name: str) -> Path:
    return Path(env("REX_PICKER_STATE")) / name


def run_rex(server: str, *args: str, **kwargs) -> subprocess.CompletedProcess:
    """`rex` against SERVER, or the server running this picker for "".
    This terminal's session and block belong to this server, so don't
    send them to another one."""
    if not server:
        return subprocess.run(["rex", *args], **kwargs)
    others = {k: v for k, v in os.environ.items() if k not in ("REX_SESSION", "REX_BLOCK")}
    return subprocess.run(["rex", "-S", server, *args], env=others, **kwargs)


def rex(server: str, *args: str, **kwargs) -> bool:
    """Whether `rex` (see run_rex) succeeded."""
    return run_rex(server, *args, **kwargs).returncode == 0


def pause() -> None:
    print("Press enter to continue.", file=sys.stderr)
    sys.stdin.readline()


# Lists ------------------------------------------------------------------------


def row(server: str, kind: str, label: str, dir: str, id: str, display: str) -> str:
    return "\t".join([server, kind, label, dir, id, display])


def list_rows(server: str) -> None:
    script = str(SCRIPT.parent / "session-list.lua")
    rex(server, "do", script, "--args", json.dumps({"server": server}))


def tilde(path: str) -> str:
    return "~" + path[len(HOME) :] if path.startswith(HOME) else path


def zoxide_rows() -> None:
    """Any directory zoxide knows, for sessions outside $REPOS (local only)."""
    found = subprocess.run(["zoxide", "query", "-l"], stdout=subprocess.PIPE, text=True)
    for dir in found.stdout.splitlines():
        print(row("", "dir", Path(dir).name, dir, "", "📂 " + tilde(dir)))


def load_servers() -> None:
    """Sets REX_PICKER_CLIENT, REX_PICKER_HOME, and REX_PICKER_REMOTES
    (one mode per line) from servers.lua, for the commands fzf runs."""
    args = json.dumps({"client_id": env("REX_PICKER_CLIENT_ID")})
    script = str(SCRIPT.parent / "servers.lua")
    found = subprocess.run(["rex", "do", script, "--args", args], stdout=subprocess.PIPE, text=True)
    remotes = []
    for line in found.stdout.splitlines():
        kind, _, value = line.partition("\t")
        if kind == "client":
            os.environ["REX_PICKER_CLIENT"] = value
        elif kind == "home":
            os.environ["REX_PICKER_HOME"] = value
        elif kind == "remote":
            remotes.append(value)
    os.environ["REX_PICKER_HOME"] = home()
    os.environ["REX_PICKER_REMOTES"] = "\n".join(remotes)


def home() -> str:
    return env("REX_PICKER_HOME") or "local"


def start_mode() -> str:
    return home() if env("REX_PICKER_START") == "home" else "local"


def server(mode: str) -> str:
    """The SERVER argument for MODE: its host label, or "" for local."""
    return mode[len("remote:") :] if mode.startswith("remote:") else ""


def server_name(mode: str) -> str:
    """A host label, or this machine's hostname for local."""
    return server(mode) or socket.gethostname().split(".")[0]


def prompt(mode: str) -> str:
    if mode == "zoxide":
        return "📂 zoxide ❯ "
    icon = "💻" if mode == home() else "🖥 "
    return f"{icon} {server_name(mode)} ❯ "


def header(remotes: list[str]) -> str:
    """The keys, with alt-r cycling through REMOTES (modes).
    Not alt-l: Rex configs often bind alt+h/j/k/l to pane resizing."""
    keys = [f"alt-s: {server_name(home())}"]
    if remotes:
        keys.append("alt-r: " + ", ".join(server_name(mode) for mode in remotes))
    if HAS_ZOXIDE:
        keys.append("alt-z: zoxide")
    keys += ["alt-p: pin", "alt-u/d: move pin", "alt-x: close"]
    return "  ".join(keys)


def current_mode() -> str:
    return state("mode").read_text().strip()


def set_mode(mode: str) -> str:
    """Remembers MODE, so reloads after pin/kill stay in it, and returns
    its prompt."""
    state("mode").write_text(mode + "\n")
    return prompt(mode)


def next_server() -> str:
    """Cycles through the remotes that answered, starting from the first."""
    remotes = state("remotes").read_text().splitlines()
    mode = current_mode()
    i = remotes.index(mode) + 1 if mode in remotes else 0
    return set_mode(remotes[i % len(remotes)])


def probe_remotes() -> None:
    """Run in the background once fzf is up (see pick), as a remote that's
    off, like a laptop, takes the connection timeout to fail. Remembers
    the remotes that answer for next_server, and prints the fzf actions
    offering alt-r for them."""
    remotes = env("REX_PICKER_REMOTES").splitlines()
    quiet = {"stdout": DEVNULL, "stderr": DEVNULL}
    answered = [m for m in remotes if rex(server(m), "api", "call", "server.version", **quiet)]
    if not answered:
        return
    state("remotes").write_text("\n".join(answered) + "\n")
    print(f"rebind(alt-r)+change-header:{header(answered)}")


def current() -> None:
    mode = current_mode()
    if mode == "zoxide":
        zoxide_rows()
    else:
        list_rows(server(mode))


def pin(server: str, label: str, dir: str, id: str) -> None:
    """Pins live on the server whose sessions they are. A session row's pin
    takes the session's directory (see toggle_pin in
    lua/rex_sessions/init.lua)."""
    session = ["-s", id] if id else []
    args = json.dumps({"label": label, "dir": dir})
    if not rex(server, "do", *session, "toggle_pin", "--args", args, stdout=DEVNULL):
        pause()


def move_pin(server: str, label: str, id: str, direction: str) -> None:
    """Moves LABEL's pin up or down a place (see move_pin in
    lua/rex_sessions/init.lua) and prints the fzf actions that reload the rows
    and follow it: a reload keeps the cursor's position, and the pins are
    the first rows. If the pin can't move, the footer says why. An open
    pin's session (ID) moves in the sidebar, which needs the call to be
    attached to it."""
    if current_mode() == "zoxide":
        return
    session = ["-s", id] if id else []
    args = json.dumps({"label": label, "by": -1 if direction == "up" else 1})
    command = ["do", *session, "move_pin", "--args", args]
    moved = run_rex(server, *command, stdout=DEVNULL, stderr=subprocess.PIPE, text=True)
    if moved.returncode == 0:
        print(f"change-footer()+reload({SELF} current)+{direction}")
    else:
        error = (moved.stderr.strip().splitlines() or ["rex failed"])[-1]
        print("change-footer:" + error.removeprefix("Error: "))


# Sessions ---------------------------------------------------------------------


def switch(server: str, label: str, **kwargs) -> bool:
    """A switch run from the CLI has no client to ask unless the app is in
    a session on that server, so target this app. It has the same label
    on every server it's connected to. JSON args keep labels like `2024`
    from being read as numbers."""
    client = ["-C", env("REX_PICKER_CLIENT")] if env("REX_PICKER_CLIENT") else []
    args = json.dumps({"label": label})
    return rex(server, *client, "do", "switch_session", "--args", args, stdout=DEVNULL, **kwargs)


def open_session(server: str, label: str, dir: str, id: str) -> bool:
    """Rows without a session id only have a directory, so create the
    session there unless one with that label already exists. A leading ~
    in DIR is this machine's home (a toggle's cwd may have one, see
    lua/rex_sessions/init.lua)."""
    if dir.startswith("~"):
        dir = HOME + dir[1:]
    if id:
        return switch(server, label)
    if switch(server, label, stderr=DEVNULL):
        return True
    if not dir:
        print(f"{label} has no session or directory. alt-p unpins it.", file=sys.stderr)
        return False
    return rex(server, "new", label, "--cwd", dir, stdout=DEVNULL) and switch(server, label)


def kill(server: str, id: str) -> None:
    if not id:
        return
    if not server and id == env("REX_SESSION"):
        print("Can't close the session this picker is running in.", file=sys.stderr)
        pause()
    elif not rex(server, "do", "-s", id, "kill_session", stdout=DEVNULL):
        pause()


def preview(server: str, kind: str, label: str, dir: str, id: str) -> None:
    """The picker's layer is the current session's focused block, so
    preview the pane it opened over instead."""
    origin = env("REX_PICKER_ORIGIN_BLOCK")
    if kind == "session":
        if not server and id == env("REX_SESSION") and origin:
            capture("", "-b", origin)
        else:
            capture(server, "-s", id)
    elif not dir:
        print(f"{label} has no session or directory. alt-p unpins it.")
    elif not server:
        preview_dir(dir)
    else:
        print(f"New session in {dir} on {server}")


def capture(server: str, *target: str) -> None:
    """Prints TARGET's screen as the terminal draws it: VT sequences keep
    its colors, such as an editor's syntax highlighting, which fzf's
    preview shows."""
    rex(server, "capture", "--format", "vt", *target)


def preview_dir(dir: str) -> None:
    """Runs the first of REX_PICKER_PREVIEW's commands that applies to
    DIR, or lists it."""
    found = readme(dir)
    commands = env("REX_PICKER_PREVIEW").splitlines()
    applicable = (preview_command(c, dir, found) for c in commands)
    subprocess.run(next(filter(None, applicable), None) or ["ls", "-la", dir])


def preview_command(command: str, dir: str, found: Path | None) -> list[str] | None:
    """COMMAND's words with {dir} and {readme} (the README FOUND in DIR)
    filled in, or with DIR added at the end when it has neither. None if
    its program isn't installed, or it shows the README and DIR has none."""
    words = shlex.split(command)
    if not words or not shutil.which(words[0]):
        return None
    if "{readme}" in command and found is None:
        return None
    if "{dir}" not in command and "{readme}" not in command:
        words.append(dir)
    return [w.replace("{dir}", dir).replace("{readme}", str(found)) for w in words]


def readme(dir: str) -> Path | None:
    """DIR's README file, preferring a bare README, then README.md, etc."""
    try:
        files = sorted(p for p in Path(dir).iterdir() if p.is_file())
    except OSError:
        return None
    return next((p for p in files if p.name.lower().startswith("readme")), None)


# Picker -----------------------------------------------------------------------


def fzf(first_prompt: str) -> str | None:
    """The chosen row, or None if fzf was cancelled. fzf reads the rows
    from FZF_DEFAULT_COMMAND, as its input is the terminal."""
    binds = {
        # alt-r is unbound until a remote answers (see probe_remotes).
        "start": f"unbind(alt-r)+bg-transform({SELF} probe-remotes)",
        "alt-s": f"transform-prompt({SELF} home)+reload({SELF} current)",
        "alt-r": f"transform-prompt({SELF} next-server)+reload({SELF} current)",
        "alt-p": f"execute({SELF} pin {{1}} {{3}} {{4}} {{5}})+reload({SELF} current)",
        "alt-u": f"transform({SELF} move-pin {{1}} {{3}} {{5}} up)",
        "alt-d": f"transform({SELF} move-pin {{1}} {{3}} {{5}} down)",
        "alt-x": f"execute({SELF} kill {{1}} {{5}})+reload({SELF} current)",
    }
    if HAS_ZOXIDE:
        binds["alt-z"] = f"transform-prompt({SELF} mode zoxide)+reload({SELF} current)"
    args = [
        "fzf", "--delimiter", r"\t", "--with-nth", "6", "--reverse", "--no-sort",
        "--border-label", " rex sessions ", "--prompt", first_prompt, "--header", header([]),
        "--bind", "tab:down,btab:up",
        *(arg for key, action in binds.items() for arg in ("--bind", f"{key}:{action}")),
        "--preview-window", "right:55%",
        "--preview", f"{SELF} preview {{1}} {{2}} {{3}} {{4}} {{5}}",
    ]  # fmt: skip
    rows = {**os.environ, "FZF_DEFAULT_COMMAND": f"{SELF} current"}
    chosen = subprocess.run(args, stdout=subprocess.PIPE, text=True, env=rows)
    return chosen.stdout.rstrip("\n") if chosen.returncode == 0 else None


def pick() -> bool:
    # State shared with the commands fzf runs, such as the mode.
    os.environ["REX_PICKER_STATE"] = tempfile.mkdtemp()
    try:
        load_servers()
        choice = fzf(set_mode(start_mode()))
    finally:
        shutil.rmtree(env("REX_PICKER_STATE"))
    if choice is None:
        return True
    srv, _, label, dir, id = (choice.split("\t") + [""] * 5)[:5]
    return open_session(srv, label, dir, id)


def main(argv: list[str]) -> None:
    command = argv[0] if argv else ""
    a = argv[1:] + [""] * 5
    if command == "open":
        load_servers()
        if not open_session(a[0], a[1], a[2], ""):
            pause()
    elif command == "mode":
        print(set_mode(a[0]))
    elif command == "home":
        print(set_mode(home()))
    elif command == "next-server":
        print(next_server())
    elif command == "probe-remotes":
        probe_remotes()
    elif command == "current":
        current()
    elif command == "pin":
        pin(a[0], a[1], a[2], a[3])
    elif command == "move-pin":
        move_pin(a[0], a[1], a[2], a[3])
    elif command == "kill":
        kill(a[0], a[1])
    elif command == "preview":
        preview(a[0], a[1], a[2], a[3], a[4])
    elif not pick():
        pause()


if __name__ == "__main__":
    main(sys.argv[1:])
