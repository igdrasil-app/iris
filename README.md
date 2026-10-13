# iris

Apple Calendar for the agents you already run: Claude Code, Cursor, Codex, OpenClaw.
One signed binary, one permission grant, a CLI and an MCP server.

Status: step 1, the permissions experiment. Not usable yet.

## Build

    make build                  # swift build + codesign; needs a Developer ID certificate
    .build/release/iris status  # prints the calendar permission state, never prompts
    .build/release/iris         # requests access, lists calendars

Copyright © 2026 Zhandos Ombayev. All rights reserved.
