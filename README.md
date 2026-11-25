# iris

Apple Calendar and Notes for the agents you already run: Claude Code, Cursor, Codex, OpenClaw.
One signed app that holds the permissions, a CLI and an MCP server.

Calendar: read and write. Notes: read.

## Why

Agents can already script Apple apps with osascript: hundreds of tokens of AppleScript per call, seconds per query, a different script every time, and the permission goes to the terminal that ran it, so from Cursor or Claude Desktop there is no prompt at all. Iris is one signed app that owns its grants, one command per task, JSON out.

## Install

    brew install --cask igdrasil-app/tap/iris
    brew upgrade --cask igdrasil-app/tap/iris

Then open Iris once with the `open` line brew prints (`open /Applications/Iris.app` unless you set another appdir), so it sits in the menu bar and macOS asks about the download while you are at the terminal rather than inside an agent's first `iris mcp`. Run `iris calendar calendars`, where macOS asks once for Calendar access, and `iris notes folders`, where it asks once to let Iris control Notes, and add iris to your agent: `claude mcp add --scope user iris -- iris mcp` for Claude Code, `iris help mcp` or [Hosts](#hosts) for the rest.

Always tap-qualified: Homebrew's own `iris` is an unrelated app that a bare `brew upgrade --cask iris` would install instead; a plain `brew upgrade` is fine. `iris doctor` says which version is installed and prints the upgrade command when a newer release exists.

Open Iris.app for a menu bar icon: the bot head, with a dot while Iris lacks full Calendar access or Notes access is denied. Its menu shows the Calendar and Notes permission state; for Calendar it asks for access or opens Privacy Settings, for Notes it asks (Allow Notes Access…, while Notes is open) or opens Automation Settings. It also shows the version, and can open Iris at login. `brew upgrade` quits the menu bar and reopens the new version; running `iris mcp` servers are left alone.

While it runs, the menu bar app updates Iris itself: it checks once a day, offers a new version, and has Check for Updates… next to the version. The update replaces Iris.app in place with the same signature, so the Calendar grant, `/opt/homebrew/bin/iris` and running `iris mcp` servers carry on, and the next `iris` starts without a Gatekeeper dialog. A plain `brew upgrade` skips Iris once the app is current; the tap-qualified upgrade reinstalls it, because brew still records the version it installed.

## Use

    iris --help
    iris status                                                     # Calendar and Notes permission state, never prompts
    iris doctor                                                     # version, path, Calendar and Notes permission state, newer release if any
    iris calendar calendars                                         # id, title, writable, source
    iris calendar events                                            # next 7 days, every calendar
    iris calendar events --from 2026-10-13 --to 2026-10-20 --calendar Work
    iris calendar events --title "bus pickup"                       # title contains the text, ignoring case
    iris calendar add --calendar Work --title "Standup" --start 2026-10-19T09:30 --repeat weekly --on mo,we --count 8
    iris calendar update <id> --occurrence 2026-10-21T09:30 --start 2026-10-21T10:00   # one occurrence; it gets its own id and detached: true
    iris calendar delete <id>                                       # --occurrence <date> for one, --span future for the rest
    iris notes folders                                              # id, name, account, parent, noteCount
    iris notes list --folder Work --since 2026-10-01 --limit 10    # newest modified first, 50 by default
    iris notes search "dentist invoice" --limit 5                   # every word in title or text; snippet of the text
    iris notes show <id>                                            # one note with its text; --html adds the HTML body
    iris mcp                                                        # MCP server over stdio; hosts start it, see below
    iris mcp --http                                                 # over HTTP on 127.0.0.1:8765, behind a token: reads, writes if turned on

Dates in are `2026-10-13`, `2026-10-13T09:00` (local time) or ISO 8601 with an offset or `Z`, seconds and fractions optional; a bare date given as an end (`--to`, `--end`, `--until`) includes that whole day. Dates out are ISO 8601 in the Mac's zone.

## Hosts

`iris mcp` serves the calendar and notes commands as MCP tools over stdio: `calendars`, `events`, `add_event`, `update_event`, `delete_event`, `note_folders`, `notes`, `search_notes`, `show_note`, with the fields of the commands. A call still running after 60 seconds is stopped and returns an error, so the server keeps answering. Any host that starts local MCP servers can use it. Claude Code, Codex and Grok CLI:

    claude mcp add --scope user iris -- iris mcp
    codex mcp add iris -- iris mcp
    grok mcp add iris -- iris mcp

OpenClaw's Gateway has its own PATH, so it gets the binary inside the app:

    openclaw mcp add iris --command /Applications/Iris.app/Contents/MacOS/iris --arg mcp

Cursor (`~/.cursor/mcp.json`) and Claude Desktop (`~/Library/Application Support/Claude/claude_desktop_config.json`) are apps without Homebrew on their PATH, so they get the binary inside the app:

    { "mcpServers": { "iris": { "command": "/Applications/Iris.app/Contents/MacOS/iris", "args": ["mcp"] } } }

Hermes (`~/.hermes/config.yaml`):

    mcp_servers:
      iris:
        command: iris
        args: [mcp]

Muse Code (`~/.config/muse/settings.json`):

    { "schema_version": 1, "mcpServers": { "iris": { "command": "iris", "args": ["mcp"] } } }

### Over HTTP

`iris mcp --http` serves the read tools (`calendars`, `events`, `note_folders`, `notes`, `search_notes`, `show_note`), and the calendar writes only if you turn them on (below), at `http://127.0.0.1:8765/mcp` (a request gets one JSON reply and a notification an empty 202), for a host that cannot start a process on this Mac. It listens on 127.0.0.1 and nowhere else, and every request needs `Authorization: Bearer <token>`, with the token read at start from `~/Library/Application Support/Iris/http-token` (or `--token-file`; `--port` changes the port). Iris never creates the token file; this does:

    mkdir -p ~/Library/Application\ Support/Iris
    (umask 077; openssl rand -base64 32 > ~/Library/Application\ Support/Iris/http-token)

A caller sees only the calendars and note folders named in `~/Library/Application Support/Iris/http-scope` (or `--scope-file`), and without that file the server does not start. It is JSON with both keys; each holds names or ids, `"all"`, or `[]` for none:

    (umask 077; echo '{"calendars": ["Work"], "folders": "all"}' \
      > ~/Library/Application\ Support/Iris/http-scope)

Anything else does not exist for the caller: naming it gets the same error as a name that matches nothing, and a note is there only when an allowed folder shows it, smart folders included. Names are matched to ids at start, so restart the server after changing the file; a calendar or folder created later is not included, even under an allowed name, unless the key says `"all"`.

Writes are off unless the scope file also says `"writes": true`:

    (umask 077; echo \
      '{"calendars": ["Work"], "folders": "all", "writes": true}' \
      > ~/Library/Application\ Support/Iris/http-scope)

Then `add_event`, `update_event` and `delete_event` are offered too, in the scope's calendars only: any other calendar, and any event in one, answers as one that does not exist, and nothing is changed. Notes stay read only. The guards are for a mistaken or misled assistant: one write at a time; at most 20 write calls an hour, a refused one included, counted across restarts in `http-write-times`; and `delete_event` never deletes a whole series (`span future` is refused; do that on the Mac). `update_event` with `span future` and `add_event` with `repeat` still change or create a whole series in one call. Every write that reached its command is recorded in `http-writes.log` with the text iris returned, the changed event for a success, so a wrong change can be undone by hand; that file holds calendar content and is trimmed to its newest lines when it passes 4 MB, the newest entry always kept whole. Both files are owner-only (mode 600, no access control list), in `~/Library/Application Support/Iris` or `--state-dir`. That folder must be yours and writable by you only, and one server with writes on uses it at a time; otherwise the server does not start.

The token stops a web page in your browser (which is also refused for sending an Origin header), another user of this Mac, and anything arriving through a proxy of yours. It does not stop a process running as you on this Mac, which can read the file or run iris itself. `iris help mcp` has the rest.

Assistants that run in a vendor's cloud, such as Grok Bot, the Meta Muse app and Hark Pro, cannot start a process on this Mac. They can be served only if you put a proxy of your own in front of `iris mcp --http`, which makes the calendars and notes in its scope reachable from the internet behind that one token; Iris does not do that for you.

## Build and release

    make app                     # universal swift build, bundle as build/Iris.app, codesign; needs a Developer ID certificate
    build/Iris.app/Contents/MacOS/iris status
    swift test                   # the HTTP gate (token, Origin, path, method, body framing), scope (who sees what), write guards, alarm minutes, availability, attendees
    ./release.sh                 # the version in Info.plist: notarize, tar, GitHub release, bump the cask and the Sparkle appcast
                                 # bump CFBundleVersion with the version; Sparkle compares only that, and release.sh refuses a repeat
                                 # over SSH or from an agent, where the keychain cannot prompt: NOTARY_KEY=<p8> NOTARY_KEY_ID=<id> NOTARY_ISSUER=<uuid> SPARKLE_KEY=<file> ./release.sh

Copyright © 2026 Jandos Meirkhan. MIT License, see LICENSE.
