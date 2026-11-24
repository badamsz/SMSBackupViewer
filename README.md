# SMS Backup Viewer

[![CI](https://github.com/badamsz/SMSBackupViewer/actions/workflows/ci.yml/badge.svg)](https://github.com/badamsz/SMSBackupViewer/actions/workflows/ci.yml)
![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue)
![Swift](https://img.shields.io/badge/Swift-5.9%2B-orange)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

A native macOS app for browsing and searching Android backups made with
[SMS Backup & Restore](https://play.google.com/store/apps/details?id=com.riteshsahu.SMSBackupRestore),
plus a bundled local **MCP server** so Claude (or any MCP client) can search your texts and call log.

- Messages-style conversation view with SMS, MMS group chats, photos and other attachments
- Instant full-text search (SQLite FTS5) across every message, with match highlighting and jump-to-context
- Call log browser with filters (incoming, outgoing, missed, voicemail, rejected/blocked)
- Imports any number of `sms-*.xml` / `calls-*.xml` files, or `.zip` archives containing them, and de-duplicates overlapping backups
- Handles multi-GB backups by streaming them, and tolerates the quirks real backups contain (emoji written as
  surrogate-pair entities, control characters, huge base64 video attachments)
- Everything stays on your Mac. Backups are indexed into
  `~/Library/Application Support/SMSBackupViewer/messages.sqlite`, and the original XML files are never modified.

## Build

Requirements: macOS 14 (Sonoma) or later and **Xcode** (open it once after installing). The Command Line Tools alone
can build the MCP server but not the app, because they lack the SwiftUI macro plugin. `build-app.sh` uses Xcode automatically
when it is installed, even if `xcode-select` points at the Command Line Tools.

```bash
./build-app.sh             # → build/SMS Backup Viewer.app
./build-app.sh --install   # also copies it to /Applications
./build-app.sh --universal # arm64 + x86_64
```

For development you can also run `swift run SMSBackupViewer`, or open `Package.swift` in Xcode.

Tests:

```bash
swift test                     # parser, zip import, database and search tests
./Scripts/mcp-smoke-test.sh    # end-to-end MCP check against the sample backups
```

Every push and pull request runs both on GitHub Actions, which also uploads the built app as a workflow artifact.

The app is ad-hoc signed. Because you build it yourself, Gatekeeper shouldn't block it. If macOS still complains,
right-click the app and choose **Open**.

## Using the app

1. Export your backups from the phone. SMS Backup & Restore writes files named like `sms-20261119123000.xml` and
   `calls-20261119123000.xml` to local storage, Google Drive, Dropbox or OneDrive.
2. Drag the files onto the window, or press **⌘O**. Zipped backups work too: every `.xml` inside the archive is
   imported (unzipped to a temporary folder with macOS's built-in `ditto`, then cleaned up). Password-protected
   zips aren't supported; unzip those in Finder first.
3. Browse conversations in the sidebar, or type in the sidebar search field to search every message.
   Words match by prefix (`light` finds "lighthouse"), and `"quoted phrases"` match exactly.
   Click a result to open the conversation scrolled to that message, with the match highlighted.
4. Double-click an attachment to open it. Right-click for **Save As…** and **Copy Image**.
5. Press **⌘2** for the call log and **⌘1** to go back to messages.

Re-importing a newer backup only adds messages you don't already have.

## MCP server

`smsbackup-mcp` ships inside the app bundle (`SMS Backup Viewer.app/Contents/MacOS/smsbackup-mcp`) and speaks MCP
over stdio. It reads the same database as the app.

**Easiest setup:** open the app and go to **Settings (⌘,) → MCP Server**:
- **Add to Claude Desktop** merges the server into `~/Library/Application Support/Claude/claude_desktop_config.json`
  and saves a `.bak` of the previous file. Restart Claude afterwards.
- **Claude Code**: copy the `claude mcp add …` command it shows.

Manual Claude Desktop config:

```json
{
  "mcpServers": {
    "sms-backup": {
      "command": "/Applications/SMS Backup Viewer.app/Contents/MacOS/smsbackup-mcp"
    }
  }
}
```

### Tools

| Tool | What it does |
|---|---|
| `search_messages` | Full-text search with optional filters: `contact`, `conversation_id`, `after`/`before` dates, `direction`, `has_attachments`, and paging |
| `list_conversations` | Lists threads by most recent activity, optionally filtered by name or number |
| `get_conversation` | Reads a thread chronologically: latest messages, around a message id, or before/after a date |
| `get_message` | Returns one full message plus its attachment list |
| `get_attachment` | Returns MMS images as viewable image content, and text or vCards as text |
| `search_calls` | Searches the call log by contact, type and date |
| `get_stats` | Gives counts, date range, most active conversations and imported files |
| `import_backup` | Imports an `.xml` file or a `.zip` of them by path (the only tool that writes) |

Example prompts: *"When did Alex and I last talk about the lighthouse trip?"*,
*"Summarize my texts with Sam from March 2024"*, *"How many missed calls did I get last week?"*

### Command line

The same binary also works as a small CLI:

```bash
smsbackup-mcp import ~/Downloads/sms-20261119123000.xml ~/Downloads/calls-20261119123000.xml
smsbackup-mcp import ~/Downloads/backups.zip
smsbackup-mcp stats
smsbackup-mcp --db /path/to/other.sqlite      # use a different database (or set SMS_BACKUP_DB)
```

## Project layout

```
Sources/SMSBackupCore/    Streaming XML parser, SQLite store, search (shared)
Sources/SMSBackupViewer/  SwiftUI app
Sources/SMSBackupMCP/     MCP server + CLI (no third-party dependencies)
Samples/                  Small synthetic sms/calls backups (xml and zip) to try things out
Scripts/                  MCP smoke test
Tests/                    Parser, zip and store tests
.github/workflows/ci.yml  Build, test and smoke test on macOS
```

## Notes

- Conversations are grouped by participant phone numbers, using the last 10 digits, so `+1 (207) 555-0100` and
  `2075550100` end up in the same thread.
- Contact names come from the `contact_name` that SMS Backup & Restore records at backup time.
- Attachments are stored in the database, so it ends up about ¾ the size of your XML backups.

## Privacy

SMS Backup Viewer runs entirely on your Mac and makes no network connections. Your messages are stored in a local
SQLite database that only you can read. The MCP server reads that same database and runs only when an MCP client you
configured (such as Claude Desktop) starts it. Anything a tool returns is then sent to that client, so connect it only
to assistants you trust with your messages. All files in `Samples/` are synthetic; no real messages are included.

## License

[MIT](LICENSE)

*SMS Backup & Restore is a product of SyncTech Pty Ltd. This project is independent, and is not affiliated with or
endorsed by SyncTech.*
