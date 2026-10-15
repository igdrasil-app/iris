# iris

Apple Calendar for the agents you already run: Claude Code, Cursor, Codex, OpenClaw.
One signed app, one permission grant, a CLI and an MCP server.

Status: step 2, read-only calendar commands.

## Why

Agents can already script Apple apps with osascript: hundreds of tokens of AppleScript per call, seconds per query, a different script every time, and the permission goes to the terminal that ran it, so from Cursor or Claude Desktop there is no prompt at all. Iris is one signed app that owns its grants, one command per task, JSON out.

## Build

    make app                     # swift build, bundle as build/Iris.app, codesign; needs a Developer ID certificate
    cp -R build/Iris.app /Applications/
    ln -sf /Applications/Iris.app/Contents/MacOS/iris ~/bin/iris   # until the brew cask exists

## Use

    iris --help
    iris status                                                     # permission state, never prompts
    iris calendar calendars                                         # id, title, writable, source
    iris calendar events                                            # next 7 days, every calendar
    iris calendar events --from 2026-10-13 --to 2026-10-20 --calendar Work

Dates in are `2026-10-13`, `2026-10-13T09:00` (local time) or ISO 8601 with an offset or `Z`, seconds and fractions optional; dates out are ISO 8601 in the Mac's zone.

Copyright © 2026 Zhandos Ombayev. All rights reserved.
