# iris, working agreement

iris is a macOS binary that gives coding agents (Claude Code, Cursor, Codex, OpenClaw) access to Apple apps, Calendar first. Swift, SwiftPM, macOS 14+, no dependencies unless they earn their place.

- This is the only instruction file. Do not add CLAUDE.md or similar; Claude Code and Codex both read AGENTS.md.
- One change per step, small enough to read as a single diff. Finish and verify a step before starting the next.
- No documents beyond README.md and this file. No tests unless a behaviour could break silently and running it by hand would not catch it.
- `make app` builds and signs `build/Iris.app`; the CLI is the binary inside it. Signing with the Developer ID is not optional: macOS binds permission grants to the bundle id and the signing identity.
- The binary must never depend on the current directory; agents run it from anywhere.
- CLI contract: JSON on stdout; errors on stderr, exit 1 at runtime and 64 for usage; dates in ISO 8601 with the Mac's offset. `--help` is the documentation agents read; keep it complete.
- `iris mcp` serves the calendar, notes and reminders commands as tools over stdio and writes nothing else to stdout. A tool is its command: a new option needs a row in the table in `Sources/iris/MCPTools.swift`.
- `iris mcp --http` offers the read tools named in `Sources/iris/MCPHTTP.swift`, and the calendar writes only when the scope file says `"writes": true`, on 127.0.0.1 only, behind a token read from a file (never an argument or the environment). Its stdout is one ready line; the request log goes to stderr and never holds arguments, results or the token.
- Over HTTP, unless its scope-file key is "all", every tool call carries the scope file's ids, pinned at start, as `--allowed-calendars` or `--allowed-folders`; the commands enforce them, and out of scope answers exactly like nonexistent.
- Over HTTP every write passes the guards in `Sources/iris/MCPHTTPWrites.swift`: one at a time, counted and saved before it runs, never a series delete, recorded after. The state folder is locked by one server and must be the user's alone; its files are mode 600 with no ACL.
- Over HTTP, unless the scope file says `"sharedEvents": true`, every update_event and delete_event carries `--only-mine`, pinned at start like the scope: an event with anyone else on it is refused, and so is `--span future` on a repeating event, after scope and existence and before any change.
- A calendar name that matches nothing is an error, never a silent widening to every calendar.
- Writes change one event per call and print the result. A recurring event needs `--occurrence` or `--span future`; placeholder ids and read-only calendars are refused.
- Reminders are read only so far: `iris reminders lists` and `iris reminders list` (tools `reminder_lists` and `reminders`, stdio only). EventKit reads an empty list of lists as every list: never pass one.
- Notes are read only, through batched Apple Events: one event per property, never one per note. The only caller text ever put into a script is a note id that passed the id check.
- Plain, readable Swift over clever Swift. Comment only what the code does not already say.
