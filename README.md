# iris

Apple Calendar for the agents you already run: Claude Code, Cursor, Codex, OpenClaw.
One signed app, one permission grant, a CLI and an MCP server.

Status: step 4, release script and brew cask.

## Why

Agents can already script Apple apps with osascript: hundreds of tokens of AppleScript per call, seconds per query, a different script every time, and the permission goes to the terminal that ran it, so from Cursor or Claude Desktop there is no prompt at all. Iris is one signed app that owns its grants, one command per task, JSON out.

## Install

    brew install --cask igdrasil-app/tap/iris
    brew upgrade --cask igdrasil-app/tap/iris

Always tap-qualified: Homebrew's own `iris` is an unrelated app, and a bare `brew upgrade --cask iris` would install it instead. A plain `brew upgrade` is fine. The cask puts Iris.app in /Applications and links `iris` into Homebrew's bin.

## Use

    iris --help
    iris status                                                     # permission state, never prompts
    iris calendar calendars                                         # id, title, writable, source
    iris calendar events                                            # next 7 days, every calendar
    iris calendar events --from 2026-10-13 --to 2026-10-20 --calendar Work
    iris calendar add --calendar Work --title "Standup" --start 2026-10-19T09:30 --repeat weekly --on mo,we --count 8
    iris calendar update <id> --occurrence 2026-10-21T09:30 --start 2026-10-21T10:00   # one occurrence; it gets its own id
    iris calendar delete <id>                                       # --occurrence <date> for one, --span future for the rest

Dates in are `2026-10-13`, `2026-10-13T09:00` (local time) or ISO 8601 with an offset or `Z`, seconds and fractions optional; a bare date given as an end (`--to`, `--end`, `--until`) includes that whole day. Dates out are ISO 8601 in the Mac's zone.

## Build and release

    make app                     # universal swift build, bundle as build/Iris.app, codesign; needs a Developer ID certificate
    build/Iris.app/Contents/MacOS/iris status
    ./release.sh                 # the version in Info.plist: notarize, tar, GitHub release, bump the cask

Copyright © 2026 Zhandos Ombayev. All rights reserved.
