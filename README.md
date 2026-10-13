# iris

Apple Calendar for the agents you already run: Claude Code, Cursor, Codex, OpenClaw.
One signed app, one permission grant, a CLI and an MCP server.

Status: step 1, the permissions experiment. Not usable yet.

## Build

    make app                                   # swift build, bundle as build/Iris.app, codesign; needs a Developer ID certificate
    build/Iris.app/Contents/MacOS/iris status  # prints the calendar permission state, never prompts
    build/Iris.app/Contents/MacOS/iris         # requests access, lists calendars

Copyright © 2026 Zhandos Ombayev. All rights reserved.
