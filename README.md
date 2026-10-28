# iris

Apple Calendar for the agents you already run: Claude Code, Cursor, Codex, OpenClaw.
One signed app, one permission grant, a CLI and an MCP server.

Status: step 5, MCP server.

## Why

Agents can already script Apple apps with osascript: hundreds of tokens of AppleScript per call, seconds per query, a different script every time, and the permission goes to the terminal that ran it, so from Cursor or Claude Desktop there is no prompt at all. Iris is one signed app that owns its grants, one command per task, JSON out.

## Install

    brew install --cask igdrasil-app/tap/iris
    brew upgrade --cask igdrasil-app/tap/iris

Always tap-qualified: Homebrew's own `iris` is an unrelated app, and a bare `brew upgrade --cask iris` would install it instead. A plain `brew upgrade` is fine. The cask puts Iris.app in /Applications and links `iris` into Homebrew's bin. `iris doctor` says which version is installed and prints the upgrade command when a newer release exists.

## Use

    iris --help
    iris status                                                     # permission state, never prompts
    iris doctor                                                     # version, path, permission state, newer release if any
    iris calendar calendars                                         # id, title, writable, source
    iris calendar events                                            # next 7 days, every calendar
    iris calendar events --from 2026-10-13 --to 2026-10-20 --calendar Work
    iris calendar add --calendar Work --title "Standup" --start 2026-10-19T09:30 --repeat weekly --on mo,we --count 8
    iris calendar update <id> --occurrence 2026-10-21T09:30 --start 2026-10-21T10:00   # one occurrence; it gets its own id
    iris calendar delete <id>                                       # --occurrence <date> for one, --span future for the rest
    iris mcp                                                        # MCP server over stdio; hosts start it, see below

Dates in are `2026-10-13`, `2026-10-13T09:00` (local time) or ISO 8601 with an offset or `Z`, seconds and fractions optional; a bare date given as an end (`--to`, `--end`, `--until`) includes that whole day. Dates out are ISO 8601 in the Mac's zone.

## Hosts

`iris mcp` serves the calendar commands as MCP tools over stdio: `calendars`, `events`, `add_event`, `update_event`, `delete_event`, with the fields of the commands. Any host that starts local MCP servers can use it.

    claude mcp add --scope user iris -- iris mcp                    # Claude Code
    codex mcp add iris -- iris mcp                                  # Codex
    grok mcp add iris -- iris mcp                                   # Grok CLI
    openclaw mcp add iris --command /Applications/Iris.app/Contents/MacOS/iris --arg mcp   # OpenClaw; its Gateway has its own PATH

Cursor (`~/.cursor/mcp.json`) and Claude Desktop (`~/Library/Application Support/Claude/claude_desktop_config.json`) are apps without Homebrew on their PATH, so they get the binary inside the app:

    { "mcpServers": { "iris": { "command": "/Applications/Iris.app/Contents/MacOS/iris", "args": ["mcp"] } } }

Hermes (`~/.hermes/config.yaml`):

    mcp_servers:
      iris:
        command: iris
        args: [mcp]

Muse Code (`~/.config/muse/settings.json`):

    { "mcp_servers": { "iris": { "transport": "stdio", "command": "iris", "args": ["mcp"] } } }

Assistants that run in a vendor's cloud, such as Grok Bot, the Meta Muse app and Hark Pro, cannot start a process on this Mac and are not served.

## Build and release

    make app                     # universal swift build, bundle as build/Iris.app, codesign; needs a Developer ID certificate
    build/Iris.app/Contents/MacOS/iris status
    ./release.sh                 # the version in Info.plist: notarize, tar, GitHub release, bump the cask
                                 # over SSH or from an agent, where the keychain cannot prompt: NOTARY_KEY=<p8> NOTARY_KEY_ID=<id> NOTARY_ISSUER=<uuid> ./release.sh

Copyright © 2026 Zhandos Ombayev. All rights reserved.
