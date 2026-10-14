# iris, working agreement

iris is a macOS binary that gives coding agents (Claude Code, Cursor, Codex, OpenClaw) access to Apple apps, Calendar first. Swift, SwiftPM, macOS 14+, no dependencies unless they earn their place.

- This is the only instruction file. Do not add CLAUDE.md or similar; Claude Code and Codex both read AGENTS.md.
- One change per step, small enough to read as a single diff. Finish and verify a step before starting the next.
- No documents beyond README.md and this file. No tests unless a behaviour could break silently and running it by hand would not catch it.
- `make app` builds and signs `build/Iris.app`; the CLI is the binary inside it. Signing with the Developer ID is not optional: macOS binds permission grants to the bundle id and the signing identity.
- The binary must never depend on the current directory; agents run it from anywhere.
- CLI contract: JSON on stdout; errors on stderr, exit 1 at runtime and 64 for usage; dates in ISO 8601 with the Mac's offset. `--help` is the documentation agents read; keep it complete.
- A calendar name that matches nothing is an error, never a silent widening to every calendar.
- Plain, readable Swift over clever Swift. Comment only what the code does not already say.
