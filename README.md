# iris

Apple Calendar, Notes and Reminders for the agents you already run: Claude Code, Cursor, Codex, OpenClaw.
One signed app that holds the permissions, a CLI and an MCP server.

Calendar: read and write. Notes: read. Reminders: read, add, change, complete and delete.

## Why

Agents can already script Apple apps with osascript: hundreds of tokens of AppleScript per call, seconds per query, a different script every time, and the permission goes to the terminal that ran it, so from Cursor or Claude Desktop there is no prompt at all. Iris is one signed app that owns its grants, one command per task, JSON out.

## Install

    brew install --cask igdrasil-app/tap/iris
    brew upgrade --cask igdrasil-app/tap/iris

Then open Iris once with the `open` line brew prints (`open /Applications/Iris.app` unless you set another appdir), so it sits in the menu bar and macOS asks about the download while you are at the terminal rather than inside an agent's first `iris mcp`. Run `iris calendar calendars`, where macOS asks once for Calendar access, and `iris notes folders`, where it asks once to let Iris control Notes, and add iris to your agent: `claude mcp add --scope user iris -- iris mcp` for Claude Code, `iris help mcp` or [Hosts](#hosts) for the rest.

Always tap-qualified: Homebrew's own `iris` is an unrelated app that a bare `brew upgrade --cask iris` would install instead; a plain `brew upgrade` is fine. `iris doctor` says which version is installed and prints the upgrade command when a newer release exists.

Open Iris.app for a menu bar icon: the bot head, with a dot while Iris lacks full Calendar access or Notes access is denied, and a dot under it, as under a running app in the Dock, until a few seconds after the last request to the server the switch runs. Its menu starts with whether remote access (`iris mcp --http`) is on, and whether a server must be restarted to take a change of the scope file; it shows no port. While the switch's server runs and its settings need nothing, the line says who used it in the last 10 minutes and when (Hark · active just now, Hark and Claude · active 3 min ago, 4 assistants when the names do not fit, An assistant for one that gave no name), else when it was last used (On · last used 25 min ago) or On · no activity yet. Then a row for Calendar, Reminders and Notes says in grey at the right what the scope file lets a remote assistant do there (Off, Read Only, Read & Write, the words its submenu uses), also while remote access is off. Each row's submenu changes it: Off, Read Only and, for Calendar and Reminders, Read & Write; then, while the app shares something, a line that says which (All Calendars, or 3 of 7 Calendars; Lists, Folders) opens All Calendars and each calendar, list or folder, ticked while shared, with its account after its name where two share a name. A choice or tick writes the scope file at once, naming what it shares by id, and restarts the server the switch runs so it takes the change; a server run outside Iris needs a restart, and the menu says so. Off remembers what the app shared, in a file beside the scope file (`http-scope.shared-before`), and Read Only or Read & Write shares that again, without what was deleted since. When nothing of it is left, the app stays off and says so; it never turns into everything. While an app is off with something remembered, Choose Calendars (Lists, Folders) offers the items to pick from. With nothing remembered, as the first time, it shares everything. Unticking the last calendar, list or folder turns the app off, and remembers that one; an app that shares something again forgets what it remembered. A calendar, list or folder the file names that no longer exists shows as Missing, ticked, until you untick it. A tick while All is on leaves every other one shared. Before one calendar, list or folder is ticked or unticked, a Missing one removed, or an app turned on again with what it shared before, Iris lists that app again; if it cannot within 15 seconds, nothing changes and the menu says so. Quit waits up to five seconds for a tick still being applied; one not saved by then is dropped, and the file is left as the last tick that was. Changes need something shared: an app turned off loses them too. A scope file Iris cannot read is never written over: the submenu offers to reset it, keeping the old one beside it. Listing Notes folders needs Notes running, so while it is not, the folders submenu offers to open it, and turning Notes on again with folders remembered asks you to open it first. When Iris lacks what it needs for an app (Calendar short of full access, Reminders denied or write only, Notes denied) the row says Needs access, and a click opens its pane in Privacy & Security, or asks for Calendar access if that was never answered; while Notes is open, a click on its row asks to control Notes if that was never answered. Settings holds the version, Check for Updates…, Open at Login, and Let Assistants Change Events With Other People, which can be ticked only while Calendar is Read & Write and goes off with it.

The switch at the top of the menu runs remote access for you: on, Iris starts `iris mcp --http` itself, with the default token, scope and state files, keeps it running (started again if it stops) and logs its requests to `~/Library/Logs/iris-http.log`; off, it stops it. Iris remembers the choice and starts it again at launch. The first time, with no token file or no scope file, it creates them, owner-only, the scope sharing nothing (`{"calendars": [], "folders": []}`) until you name what to share; it never replaces a file that is there. The port is 8765 unless you set another and reopen Iris: `defaults write app.igdrasil.iris remoteAccessPort -int 8788`. While another `iris mcp --http` runs (a launchd job, a terminal) the switch shows it on and cannot be used, and Iris starts none; if one cannot start, the menu says so and Why It Couldn't Start… gives the server's reason. `brew upgrade` quits the menu bar and reopens the new version: `iris mcp` servers started outside Iris are left alone; remote access switched on in the menu stops and starts with the app. The names in the menu are the ones assistants give themselves when they connect, cut to ASCII letters, digits, spaces, `.`, `-` and `_`, at most 32 characters; the server hands them to the app beside the log, and the app keeps them in memory only, never in the log or any file, and forgets them when the switch is turned off. A server reports them only with `IRIS_REPORT_ACTIVITY=1` in its environment, which the menu sets for the server it starts.

While it runs, the menu bar app updates Iris itself: it checks once a day, offers a new version, and has Check for Updates… next to the version, under Settings. The update replaces Iris.app in place with the same signature, so the Calendar grant, `/opt/homebrew/bin/iris` and `iris mcp` servers started outside Iris carry on (remote access switched on in the menu stops and starts with the app), and the next `iris` starts without a Gatekeeper dialog. A plain `brew upgrade` skips Iris once the app is current; the tap-qualified upgrade reinstalls it, because brew still records the version it installed.

## What Iris sends

Iris reads your calendars, notes and reminders on this Mac and never uploads them; only an assistant you connect gets what it asks for. Your accounts' own syncing (iCloud and others) carries on as before. Iris itself makes only the requests below. None carries an account, an install id or anything from your calendars, notes or reminders. Like any request, each one reveals your IP address to the server, and macOS adds your preferred languages (`Accept-Language`).

- **The menu bar app's update check**, once a day and on Check for Updates…. It asks `https://updates.igdrasil.app/iris/appcast.xml` for the latest version, identified as `User-Agent: Iris/<version> Sparkle/<version>`, with no system profile. To know how many copies are in use, that server adds 1 to the day's count for the version and the country Cloudflare derives from the connection. It stores nothing else: no IP address, no request log. Its code is public, in [homebrew-tap/stats](https://github.com/igdrasil-app/homebrew-tap/tree/main/stats).
- **An update** is downloaded from the tap's GitHub releases, like `brew install`, with the same `User-Agent: Iris/<version> Sparkle/<version>`. That happens when you accept it, or by itself if you chose to download and install updates automatically.
- **`iris doctor`** asks GitHub's API for the latest release, as `User-Agent: iris`.

## Use

    iris --help
    iris status                                                     # Calendar, Notes and Reminders permission state, never prompts
    iris doctor                                                     # version, path, permission state, newer release if any
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
    iris reminders lists                                            # id, title, writable, source, open (not completed)
    iris reminders list --list Errands --due-to 2026-10-20          # open by default; --status completed or all
    iris reminders add --list Errands --title "Buy milk" --due 2026-10-14   # a bare date is date only; no alarm is set
    iris reminders add --list Errands --title Call --due 2026-10-14T09:00 --alarm 10 --alarm 0   # minutes before; needs a time; without one it does not notify
    iris reminders add --list Errands --title Bins --due 2026-10-14 --repeat weekly --until 2026-12-31   # repeats; needs --due
    iris reminders update <id> --due 2026-10-15 --notes ""          # only what you name changes; "" clears
    iris reminders update <id> --due 2026-10-15T10:00 --alarm 5     # replaces timed alarms; without --alarm they move with --due
    iris reminders complete <id>                                    # --undo opens it again; a repeat once more changes nothing
    iris reminders complete <id> --occurrence 2026-10-14            # a repeating one: its current due date; it moves to the next
    iris reminders delete <id>                                      # a repeating reminder is deleted whole; --not-repeating refuses it unless it has ended
    iris mcp                                                        # MCP server over stdio; hosts start it, see below
    iris mcp --http                                                 # over HTTP on 127.0.0.1:8765, behind a token: reads, writes if turned on

Dates in are `2026-10-13`, `2026-10-13T09:00` (local time) or ISO 8601 with an offset or `Z`, seconds and fractions optional; a bare date given as an end (`--to`, `--end`, `--until`) includes that whole day. Dates out are ISO 8601 in the Mac's zone. A reminder's `due` is the exception: its `date` and `time` are as kept in the reminder, not converted, and its `at` is that moment in the Mac's zone.

`iris reminders add --repeat` takes the repeat options of `iris calendar add` and needs `--due`, its first occurrence, which counts toward `--count` even off the days of `--on`. Monthly from the 29th to 31st and yearly from 29 February fall on the last day of a shorter month, as in Reminders. A date-only occurrence counts as due at the start of its day, so `--until` with a bare date still allows an occurrence due that day.

`iris reminders update` changes only the fields named and never whether it is completed. Timed alarms move with `--due`, keeping their time before it; `--alarm` replaces them and `--no-alarms` removes them. Each is written as the moment it fires, so it notifies on the Mac, iPhone and Watch; an alarm at a place is never touched. It refuses `--due`, `--alarm` and `--no-alarms` on a reminder that repeats (change those in Reminders), and a `--due` with no time on a reminder with timed alarms unless `--no-alarms` comes with it.

`iris reminders complete` completes a repeating reminder one occurrence at a time, as Reminders does: `--occurrence` names its current due date, and the reminder keeps its id, stays open and moves to its next occurrence, while the occurrence completed becomes a separate completed reminder, printed as `completedOccurrence`. The same call sent twice is refused the second time, since the date no longer matches. The last occurrence of a series that ends completes the reminder itself.

## Hosts

`iris mcp` serves the calendar, notes and reminders commands as MCP tools over stdio: `calendars`, `events`, `add_event`, `update_event`, `delete_event`, `note_folders`, `notes`, `search_notes`, `show_note`, `reminder_lists`, `reminders`, `add_reminder`, `update_reminder`, `complete_reminder`, `delete_reminder`, with the fields of the commands. A call still running after 60 seconds is stopped and returns an error, so the server keeps answering. Any host that starts local MCP servers can use it. Claude Code, Codex and Grok CLI:

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

Over HTTP the reminder tools are offered only when the scope file names reminder lists (below): `reminder_lists` and `reminders`, and `add_reminder`, `update_reminder`, `complete_reminder` and `delete_reminder` only when it also turns reminder writes on.

`iris mcp --http` serves the read tools (`calendars`, `events`, `note_folders`, `notes`, `search_notes`, `show_note`, and `reminder_lists` and `reminders` when the scope names lists), and the calendar and reminder writes only if you turn them on (below), at `http://127.0.0.1:8765/mcp` (a request gets one JSON reply and a notification an empty 202), for a host that cannot start a process on this Mac. It listens on 127.0.0.1 and nowhere else, and every request needs `Authorization: Bearer <token>`, with the token read at start from `~/Library/Application Support/Iris/http-token` (or `--token-file`; `--port` changes the port). The server never creates the token file; the menu bar's switch does (below), and so does this:

    mkdir -p ~/Library/Application\ Support/Iris
    (umask 077; openssl rand -base64 32 > ~/Library/Application\ Support/Iris/http-token)

To give a client the token, read it from that file, for example with `pbcopy < ~/Library/Application\ Support/Iris/http-token`. The client also needs an address it can reach: `http://127.0.0.1:8765/mcp` on this Mac, or the public address of a tunnel you run to it.

A caller sees only the calendars, note folders and reminder lists named in `~/Library/Application Support/Iris/http-scope` (or `--scope-file`), and without that file the server does not start. It is JSON with the keys `calendars` and `folders`, and optionally `lists` for reminder lists; each holds names or ids, `"all"`, or `[]` for none:

    (umask 077; echo '{"calendars": ["Work"], "folders": "all"}' \
      > ~/Library/Application\ Support/Iris/http-scope)

Anything else does not exist for the caller: naming it gets the same error as a name that matches nothing, and a note is there only when an allowed folder shows it, smart folders included. Names are matched to ids at start, so restart the server after changing the file; a calendar, folder or list created later is not included, even under an allowed name, unless the key says `"all"`.

Without `lists`, or with `[]`, no reminder tool is offered and Reminders is not asked at start. With names or `"all"`, `reminder_lists` and `reminders` are offered, read only unless reminder writes are on (below), and the server does not start without Reminders access:

    (umask 077; echo '{"calendars": ["Work"], "folders": "all", "lists": ["Errands"]}' \
      > ~/Library/Application\ Support/Iris/http-scope)

Calendar writes are off unless the scope file also says `"writes": true`:

    (umask 077; echo \
      '{"calendars": ["Work"], "folders": "all", "writes": true}' \
      > ~/Library/Application\ Support/Iris/http-scope)

Then `add_event`, `update_event` and `delete_event` are offered too, in the scope's calendars only: any other calendar, and any event in one, answers as one that does not exist, and nothing is changed. Notes stay read only, and reminders unless reminder writes are on (below). The guards are for a mistaken or misled assistant: one write at a time; at most 20 write calls an hour, calendar and reminder writes counted together, a refused one included, counted across restarts in `http-write-times`; and `delete_event` never deletes a whole series (`span future` is refused; do that on the Mac). `add_event` with `repeat` still creates a whole series in one call; changing a whole series with `update_event` and `span future` needs `"sharedEvents": true`. Every write that reached its command is recorded in `http-writes.log` with the text iris returned, the changed event or reminder for a success, so a wrong change can be undone by hand; that file holds calendar and reminder content and is trimmed to its newest lines when it passes 4 MB, the newest entry always kept whole. Both files are owner-only (mode 600, no access control list), in `~/Library/Application Support/Iris` or `--state-dir`. That folder must be yours and writable by you only, and one server with writes or reminder writes on uses it at a time; otherwise the server does not start.

`update_event` and `delete_event` over HTTP refuse an event that has anyone on it but you (an attendee, or an organizer who is not you), with nothing changed: changing or deleting it can notify them or cancel their meeting. A change to all future occurrences of a repeating event (`span future`) is refused too, since the people on later occurrences cannot be checked. Every such call carries `--only-mine`, which the caller cannot remove. To allow those events too, add `"sharedEvents": true` (it needs `"writes": true`):

    (umask 077; echo '{"calendars": ["Work"], "folders": "all",
      "writes": true, "sharedEvents": true}' \
      > ~/Library/Application\ Support/Iris/http-scope)

On the CLI and over stdio nothing is refused for this unless you pass `--only-mine` (`onlyMine` in the tools).

Reminder writes are off unless the scope file says `"reminderWrites": true`, which needs reminder lists named in `lists`; `"writes": true` does not turn them on:

    (umask 077; echo '{"calendars": ["Work"], "folders": "all",
      "lists": ["Errands"], "reminderWrites": true}' \
      > ~/Library/Application\ Support/Iris/http-scope)

Then `add_reminder`, `update_reminder`, `complete_reminder` and `delete_reminder` are offered too, in the scope's lists only: any other list, and any reminder in one, answers as one that does not exist, and nothing is changed. They pass the same guards as the calendar writes, with one count and one record for both. `delete_reminder` refuses a repeating reminder, which would be deleted whole: every call carries `--not-repeating`, which the caller cannot remove; delete it on the Mac, or complete its occurrences one at a time. A series that has ended, its last occurrence completed, has nothing left to lose and is deleted.

`iris remote status` (with `--scope-file` and `--token-file` as the server takes them) shows, as one JSON object, what a server started now would allow: per app, none, read, or read and write, with the calendars, folders and lists in scope by their current names; the tools it would offer; whether the scope file and token file would do, and if not, the message the server would stop with; and every `iris mcp --http` running as you, with its port and whether it started after the scope file last changed or needs a restart to take a change. It changes nothing, never shows the token, never shows a permission dialog, and is not offered as a tool, over stdio or HTTP.

The token stops a web page in your browser (which is also refused for sending an Origin header), another user of this Mac, and anything arriving through a proxy of yours. It does not stop a process running as you on this Mac, which can read the file or run iris itself. `iris help mcp` has the rest.

Assistants that run in a vendor's cloud, such as Grok Bot, the Meta Muse app and Hark Pro, cannot start a process on this Mac. They can be served only if you put a proxy of your own in front of `iris mcp --http`, which makes the calendars, notes and reminders in its scope reachable from the internet behind that one token; Iris does not do that for you.

## Build and release

    make app                     # universal swift build, bundle as build/Iris.app, codesign; needs a Developer ID certificate
    build/Iris.app/Contents/MacOS/iris status
    swift test                   # the HTTP gate (token, Origin, path, method, body framing), scope (who sees what), write guards, events with other people on them, alarm minutes, availability, attendees, the Reminders prompt time limit, how a reminder's due and priority read and are written, the start date that follows an update's due, how alarms move with the due, the due filter and the order of reminders, what complete does with a reminder and which reminder is the occurrence it completed, the repeat options add takes and the rule they make, what remote status reads from a scope file and a server's arguments, and what the menu's ticks write to the scope file
    ./release.sh                 # the version in Info.plist: notarize, tar, GitHub release, bump the cask and the Sparkle appcast
                                 # bump CFBundleVersion with the version; Sparkle compares only that, and release.sh refuses a repeat
                                 # over SSH or from an agent, where the keychain cannot prompt: NOTARY_KEY=<p8> NOTARY_KEY_ID=<id> NOTARY_ISSUER=<uuid> SPARKLE_KEY=<file> ./release.sh

Copyright © 2026 Jandos Meirkhan. MIT License, see LICENSE.
