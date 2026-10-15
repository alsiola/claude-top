# Claude Top: Specification

Status: Version 0.1.0 built (2026-10-15). This spec agrees with the code.

## 1. Summary

Claude Top is a small native macOS app. It shows three lights: red, amber, and green.

- **Red**: A Claude Code session is blocked on you. It asks a question, asks for permission, or cannot continue.
- **Amber**: A session finished its work and it is ready for your review.
- **Green**: No session needs you.

Claude Code hooks send events to the app. The app uses fixed rules for most events. For the "Stop" event, the app asks the Jev decision model (through OpenRouter) what the final message needs from you.

You install the app from a DMG. The app is not in the App Store.

## 2. Goals and non-goals

### 2.1 Goals

- Show at a glance if any Claude Code session needs you, and how urgently.
- Support many sessions at the same time.
- Never slow down or block Claude Code.
- Install and remove the hooks with one click.
- Work when the OpenRouter call fails. Use a safe fallback.

### 2.2 Non-goals (version 1)

- No App Store release.
- No Windows or Linux support.
- No remote sessions (Claude Code on the web, remote SSH hosts).
- No control of Claude from the app (no approve or deny buttons).
- No history or analytics.

## 3. Terms

| Term | Meaning |
|---|---|
| Session | One Claude Code process. The hook payload field `session_id` identifies it. |
| Event | One hook call from Claude Code, with its JSON payload. |
| Helper | A small command-line program inside the app bundle. Claude Code runs it for each event. |
| Attention | The state where a session is blocked on you (red). |
| Review | The state where a session finished and waits for your review (amber). |
| Jev | TypeSafe's decision model on OpenRouter. It returns typed answers (probabilities), not text. |

## 4. User experience

### 4.1 The light panel

- A small floating panel shows three round lights: red at the top, amber in the middle, green at the bottom.
- One light is on. The other lights are dim.
- The light that is on follows the aggregate rule in section 8.6.
- All lights are dim when the app knows of no sessions.
- The panel stays above other windows. It shows on all Spaces and over full-screen apps.
- You can drag the panel. The app remembers its position.
- The panel does not take keyboard focus.
- The red light and the amber light each have a badge. The badge shows the number of sessions in that state, if more than one.

### 4.2 The session list

Click the panel or the menu bar icon to open the session list. The list is part of version 1. Each row shows:

- A colored dot for the state.
- The project name (the last part of `cwd`) and the iTerm2 tab number.
- The iTerm2 tab title, without the status glyph and " (claude)" that Claude Code adds. Claude Code sets the title to the topic of the conversation, so the title identifies sessions that share a folder.
- The state: Needs you (red), Review (amber), Working (green), or Idle (green).
- The reason, for example "Permission: Bash", "Asks a question", or "Ready for review".
- The time since the last event.

When the list opens, the app asks iTerm2 for its live tabs (AppleScript), and it asks again every 5 seconds while the list is open. If iTerm2 does not answer, the tab number comes from `ITERM_SESSION_ID`. That number is the position when the shell started, so it can be wrong after tabs move or close.

Sort order: red sessions first, then amber, then all other sessions. In the red group and the amber group, the session that waited longest is at the top. In the other group, the most recent activity is at the top.

Row actions:

- **Click the row**: Bring the iTerm2 tab of that session to the front (section 9). If the session is red or amber, also set it to `idle` (green). Thus a wrong classification never keeps the light on: when you look at the session, the light clears.
- **Right-click the row**: Go to Session (without clearing), Clear (Set to Green), Remove from List.

### 4.3 Menu bar icon

- The menu bar icon is a small dot. It has the same color as the light that is on. It is gray when there are no sessions.
- The menu has these items: Show or hide light panel, Session list, Settings, Install hooks, Remove hooks, Quit.

### 4.4 Optional alerts

These are off by default. You can set each one for red, for amber, or for both:

- Play a sound when a session goes to that state.
- Send a macOS notification when a session goes to that state.

A webhook can also get each change. See the README, section "Webhook".

## 5. Architecture

```
Claude Code ──(hook, async)──▶ claude-top-hook (helper) ──(Unix socket)──▶ Claude Top.app
                                                                                │
                                                     Stop events only ─────────▶ OpenRouter Jev
```

### 5.1 Components

| Component | Language | Job |
|---|---|---|
| `Claude Top.app` | Swift, SwiftUI, AppKit | Socket server, state machine, UI, settings, hook installer, Jev client. |
| `claude-top-hook` | Swift (command-line tool) | Reads the hook payload from stdin. Adds local context. Sends it to the app socket. Always exits with code 0. |

The helper is in the app bundle at `Claude Top.app/Contents/MacOS/claude-top-hook`.

### 5.2 Why a helper with a Unix socket

Claude Code supports two useful hook types: `command` and `http`. This spec uses a `command` hook that runs the helper. The reasons are:

- **No noise when the app is off.** The helper exits with code 0 when the socket is not there. An `http` hook to a closed port can show a hook error in the transcript. (The exact `http` failure behavior is not verified.)
- **Async is documented for `command` hooks.** `"async": true` makes sure that the hook does not block Claude. The docs do not show `async` for `http` hooks.
- **Terminal context.** Only a process can read `$PPID` and terminal variables such as `TERM_PROGRAM` and `ITERM_SESSION_ID`. The app needs these to focus the correct window.
- **No port and no token.** The socket file has mode `0600`. Only your user can connect. No other app can claim the port first.

**Alternative (not chosen):** an `http` hook to `http://127.0.0.1:<port>/hook`. This needs no helper. But it loses terminal context and it has the problems above.

### 5.3 Socket

- Path: `~/Library/Application Support/ClaudeTop/hook.sock`.
- Mode: `0600`. The directory has mode `0700`.
- Protocol: one JSON object per connection. The helper writes the object, then closes the connection. The app does not reply.
- At start, the app deletes a stale socket file and makes a new one.

## 6. The helper (`claude-top-hook`)

### 6.1 Behavior

1. Record the current time in milliseconds.
2. Read all of stdin. Stop at 1 MB.
3. Parse the JSON. If the parse fails, exit with code 0.
4. Make an envelope (section 6.2).
5. Connect to the socket. Use a total time limit of 500 ms.
6. Write the envelope. Close the connection.
7. Exit with code 0 in all cases. Write nothing to stdout.

The helper must not write to stdout, because Claude Code parses stdout as hook output. The helper writes errors to a log file only if the `CLAUDE_TOP_DEBUG` environment variable is set.

### 6.2 Envelope

```json
{
  "v": 1,
  "ts_ms": 1792065600123,
  "payload": { "...": "the hook payload, unchanged" },
  "context": {
    "ppid": 51234,
    "claude_pid": 50990,
    "term_program": "iTerm.app",
    "iterm_session_id": "w0t1p0:ABCD-...",
    "bundle_id": "com.googlecode.iterm2"
  }
}
```

- `ppid`: The parent process ID of the helper. This is a shell, because Claude Code runs hooks through a shell. The shell exits with the hook.
- `claude_pid`: The first ancestor that is not a shell (`sh`, `bash`, `zsh`, and so on). This is the Claude Code process. The app uses it for liveness checks.
- `bundle_id`: The value of `__CFBundleIdentifier`, if present.
- The helper sends only the environment variables in this list. It does not send the full environment.

## 7. Hook configuration

### 7.1 Events to register

| Event | Matcher | Why |
|---|---|---|
| `SessionStart` | (none) | Add the session. Record terminal context. |
| `SessionEnd` | (none) | Remove the session. |
| `UserPromptSubmit` | (none) | You replied. Set to `working`. |
| `PreToolUse` | (none) | Claude works. Set to `working`. |
| `PostToolUse` | (none) | Claude works. This also clears a granted permission request. |
| `PostToolUseFailure` | (none) | Claude works. This also clears a denied permission request. |
| `PermissionRequest` | (none) | Claude waits for approval. Set to `attention`. |
| `Notification` | (none) | Some types need you. See section 8. |
| `Stop` | (none) | Claude finished its turn. Classify with Jev. |
| `StopFailure` | (none) | The turn ended with an API error. Set to `attention`. |

The app does not register `SubagentStop`. That event ends a subagent, not the main turn.

### 7.2 Example entry

The installer adds one entry like this for each event in section 7.1:

```json
{
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "'/Applications/Claude Top.app/Contents/MacOS/claude-top-hook'",
            "async": true,
            "timeout": 5
          }
        ]
      }
    ]
  }
}
```

### 7.3 Installer

- The installer writes to `~/.claude/settings.json`.
- It merges its entries into the current `hooks` object. It does not replace other hooks.
- It finds its own entries by the helper path. Thus install is idempotent. Remove deletes only its own entries.
- Before it writes, it shows you the change and asks for approval.
- Before it writes, it saves a backup as `~/.claude/settings.json.claude-top-backup-<timestamp>`.
- It writes to a temporary file, then renames it. This prevents a partial file.
- If the file is not valid JSON, the installer stops and tells you. It does not change the file.
- If the app moves, the installer updates the helper path at next start, after it asks you.

## 8. State machine

### 8.1 Session states

| State | Light | Meaning |
|---|---|---|
| `working` | green | Claude is busy. |
| `idle` | green | Claude stopped and does not need you. |
| `review` | amber | Claude finished and its work is ready for your review. |
| `attention` | red | Claude is blocked on you. |

The app keeps one record for each `session_id`:

```
session_id, cwd, state, reason, last_event_ts_ms, context, stop_classification
```

### 8.2 Transitions

| Event | Condition | New state | Reason text |
|---|---|---|---|
| `SessionStart` | `source` is not `compact` | `idle` | — |
| `SessionStart` | `source` is `compact` | no change | — |
| `UserPromptSubmit` | (any) | `working` | — |
| `PreToolUse`, `PostToolUse`, `PostToolUseFailure` | main agent only (no `agent_id`) | `working` | — |
| `PermissionRequest` | (any) | `attention` | "Permission: <tool_name>" |
| `Notification` | `notification_type` is `permission_prompt` | `attention` | "Permission request" |
| `Notification` | `notification_type` is `elicitation_dialog`, `elicitation_url_dialog`, or `agent_needs_input` | `attention` | "Needs input" |
| `Notification` | `notification_type` is `idle_prompt` | no change | — |
| `Notification` | all other types | no change | — |
| `Stop` | main agent only (no `agent_id`) | Result of the classifier (section 10) | From the classifier |
| `StopFailure` | (any) | `attention` | "Turn failed with an error" |
| `SessionEnd` | (any) | Remove the session | — |
| Dismiss (user action) | (any) | `idle` | — |

Notes:

- Fixed rules handle all events except `Stop`. The app does not call Jev for them.
- Subagents run in parallel with the main agent. Background subagents can run after the main agent stops. Thus tool events from a subagent (with `agent_id`) do not change the state. A `PermissionRequest` or a `Notification` from a subagent still sets `attention`.
- `idle_prompt` comes when you did not reply for some time. It does not change the state. The `Stop` classification already set the correct color.
- If you press Esc at a permission prompt, Claude Code can stop without a `Stop` event. The session then stays red until you send a prompt or click Dismiss.

### 8.3 Order of events

The hooks run async, so events can arrive out of order.

- The app sorts events by `ts_ms` from the helper.
- The app ignores an event if its `ts_ms` is older than the last event that it applied to that session.
- When a `Stop` classification completes, the app applies the result only if the state of that session did not change after the `Stop`. For example, if you type a reply before Jev answers, the session stays `working`. An event that does not change the state, such as `idle_prompt`, does not cancel the classification.

### 8.4 Stale sessions

A session can end without a `SessionEnd` event, for example after a crash.

- Every 30 seconds, the app checks if the `claude_pid` of each session is still alive (`kill(pid, 0)`). If the process is gone, the app removes the session.
- If a session has no `claude_pid` and no `ppid`, the app removes it after 12 hours with no events.

### 8.5 Sessions with no events

The app finds a session only from its hook events. Two cases have no events:

- The session started before the hooks were installed.
- The session waits for input, and the app started after its last event.

Thus the app also:

- Saves its sessions to `~/Library/Application Support/ClaudeTop/sessions.json`, and loads them at start. A pending classification is not saved.
- Scans for processes named `claude` (at start, every 30 seconds, and when the list opens). For each process with no session, it reads the working folder and `ITERM_SESSION_ID`, and shows a gray row: "No events yet". These rows do not change the light, except that the light is green (not off) when they are the only rows. A real event from the same process replaces the gray row.

### 8.6 Aggregate light

The most urgent session sets the light:

1. Red if one or more sessions are `attention`.
2. Else amber if one or more sessions are `review`.
3. Else green if there are sessions.
4. Else all lights are dim.

## 9. Go to session

All sessions run in iTerm2. The app supports only iTerm2.

1. Get the UUID from `ITERM_SESSION_ID`. The value has the form `w0t1p0:<UUID>`. The UUID is the part after the colon.
2. Run AppleScript. For each window, tab, and session of `application "iTerm2"`, compare `unique id` of the session with the UUID.
3. When it finds the session, select the window, the tab, and the session. Then activate iTerm2.
4. If `ITERM_SESSION_ID` is not set, or the session is not found, activate iTerm2 only.

The app asks for Automation permission (Apple Events) for iTerm2 the first time.

This feature is in milestone 3. It is not necessary for the lights.

## 10. Stop classifier (Jev)

### 10.1 Why a model

A `Stop` event means Claude finished its turn. The turn can end in different ways:

- With a question or a decision for you, or a report that Claude is blocked (red).
- With finished work that you must review or test (amber).
- With an answer or a status that needs nothing from you (green).

Fixed rules cannot tell these apart well. Jev returns a probability for each case, so the app can use thresholds.

### 10.2 Input

The app sends only these fields:

| Field | Source | Limit |
|---|---|---|
| `last_assistant_message` | `Stop` payload | Last 4,000 characters |
| `project` | Last part of `cwd` | — |
| `background_tasks` | Count from the `Stop` payload | — |

The app does not send the transcript, file contents, or tool inputs.

### 10.3 Request

```
POST https://openrouter.ai/api/alpha/decisions
Authorization: Bearer <OpenRouter API key>
Content-Type: application/json
```

```json
{
  "model": "~typesafe/jev-latest",
  "state": {
    "project": "claude-top",
    "background_tasks": "0",
    "last_assistant_message": "I changed the parser. Do you want me to also update the CLI flags, or keep this PR small?"
  },
  "questions": {
    "outcome": {
      "type": "choice",
      "instructions": "An AI coding agent ended its turn with this message. Pick the label that best describes what the user must do now.",
      "criteria": {
        "question": "The message asks the user a question, or asks the user to choose, decide, or approve something before the agent continues.",
        "blocked": "The agent cannot continue because of an error, missing access, missing credentials, or missing information, and the user must fix it.",
        "review": "In this turn the agent finished a change (code, files, a pull request, a deploy, or a document), and the result is ready now for the user to review, test, or merge.",
        "done": "No result is ready for the user now. The message answers a question, reports status or progress, explains a plan, or says that work continues elsewhere (for example in another agent or in the background) and that the agent will report later. Optional offers such as 'let me know if you want more' do not count as a question."
      }
    }
  }
}
```

### 10.4 Response

```json
{
  "answers": {
    "outcome": {
      "type": "choice",
      "choice": "question",
      "confidence": 0.81,
      "probabilities": { "question": 0.88, "blocked": 0.04, "review": 0.05, "done": 0.03 }
    }
  },
  "usage": { "cost": 0.00004 }
}
```

### 10.5 Decision

Let `P(x)` be `outcome.probabilities.x`.

1. Let `p_red = P(question) + P(blocked)`. If `p_red` ≥ the red threshold (default 0.5), set `attention`.
2. Else, let `p_amber = p_red + P(review)`. If `p_amber` ≥ the amber threshold (default 0.5), set `review`.
3. Else set `idle`.

Step 2 adds `p_red` to `P(review)`. Thus a message that is between red and amber goes to amber, not to green. When the model is not sure, the light shows more urgency, not less.

Reason text: use the label with the highest probability in the group that set the state. The texts are "Asks a question", "Blocked", "Ready for review", and "Done".
- Time limit for the call: 5 seconds. While the call runs, the session keeps its previous state.

### 10.6 Fallback

If there is no API key, the call fails, the call times out, or the response is not valid, the app uses a local rule:

- Set `attention` if the last 300 characters of the message contain a `?`.
- Else set `review`. Claude stopped, so there is probably work to look at. A false alarm is better than a missed request.

The reason text shows "(offline rule)" when the app uses the fallback.

### 10.7 Cost

- Jev charges for input tokens only. Output tokens are free.
- One call for each `Stop` event. The input is less than about 1,500 tokens.
- The app shows the total of `usage.cost` for the current day in Settings.

### 10.8 Evaluation

`Tests/Fixtures/stop-messages.json` holds real `Stop` messages with the expected state. `swift run claude-top-eval` sends each message to Jev and prints the probabilities and the result. The key comes from `OPENROUTER_API_KEY`, or else from the Keychain item of the app (macOS asks for permission). Run it after each change to the criteria, and add each wrong classification to the file.

### 10.9 Risk: alpha API

The Decisions API path contains `alpha`. It can change. Keep all Jev code in one module (`JevClassifier`) behind a protocol, so that a change has a small effect. The model ID is a setting. Pin a version (for example `typesafe/jev-1.14`) if the `latest` alias causes changes in behavior.

## 11. Settings

| Setting | Default | Storage |
|---|---|---|
| OpenRouter API key | (empty) | Keychain |
| Use Jev for Stop events | On | UserDefaults |
| Model ID | `~typesafe/jev-latest` | UserDefaults |
| Red threshold | 0.5 | UserDefaults |
| Amber threshold | 0.5 | UserDefaults |
| Sound on red / on amber | Off / Off | UserDefaults |
| Notification on red / on amber | Off / Off | UserDefaults |
| Show light panel | On | UserDefaults |
| Send state changes to a webhook | Off | UserDefaults |
| Webhook URL and headers | (empty) | Keychain |
| Open at login | Off | `SMAppService.mainApp` |

## 12. Privacy and security

- **Data leaves the Mac.** With Jev on, the last assistant message goes to OpenRouter and TypeSafe. This message can contain code, file paths, or customer data. Use of OpenRouter has approval (2026-10-15). The "Use Jev" setting turns it off. Then the app sends nothing out.
- The API key is in the Keychain. It is not in a file or in UserDefaults.
- **Webhook.** With the webhook on, the project name, folder path, state, and reason of each session go to the URL that you set. The URL and the headers are in the Keychain, because both can contain a secret. Plain HTTP is possible only for local hosts (`NSAllowsLocalNetworking`). See the README for the event format.
- The socket allows only your user (mode `0600`).
- The app does not log payloads, unless debug mode is on. Debug logs go to `~/Library/Logs/ClaudeTop/`.
- The app is not sandboxed. It must write `~/.claude/settings.json`, make a socket in Application Support, and send Apple Events.

## 13. Facts to verify before build

The research for this spec read the Claude Code docs through a summary tool. Some items are now verified. Verify the other items on the raw docs and in real sessions.

| # | Item | Status |
|---|---|---|
| 1 | If you omit `matcher`, the entry applies to all tools and all notification types. | Open. Other hooks on the build Mac use no matcher and get all events. |
| 2 | `async: true` on a `command` hook does not block Claude. | Open. Other hooks on the build Mac use `async: true`. |
| 3 | The parent process of the helper is the Claude Code process. | **No.** The parent is a shell (`zsh`), and the shell's parent is `claude`. The helper goes up past the shell (`claude_pid`). Verified from a shell that Claude Code started. |
| 4 | `TERM_PROGRAM` and `ITERM_SESSION_ID` reach the hook process. | Verified for processes that Claude Code starts. Check again in a real hook. |
| 5 | `PermissionRequest` fires only when a dialog shows. | Open. |
| 6 | The `SessionEnd` payload fields. | Not needed. The app uses only `session_id`. |
| 7 | A denied permission causes an event that clears `attention`. | Open. Dismiss is the fallback. |
| 8 | The Jev request accepts `state` as an object of strings. | Open. The endpoint exists (HTTP 401 without a key). Test with a real key. |

## 14. Build and distribution

### 14.1 Project

- Target: macOS 14 (Sonoma) or later. Universal binary (Apple silicon and Intel).
- Swift Package Manager. Xcode is not necessary. The Command Line Tools are sufficient.
- Targets:
  - `ClaudeTopCore`: library with all logic that has no UI (state machine, classifier, installer, JSON). The tests use this target.
  - `ClaudeTop`: the app.
  - `claude-top-hook`: the helper.
- `scripts/build-app.sh` builds each architecture, joins them with `lipo`, makes the `.app` bundle and `Info.plist`, draws the icon, and signs the bundle.
- No hardened runtime and no notarization, because there is no Developer ID certificate.
- `LSUIElement = YES`. The app has no Dock icon.
- No third-party dependencies in version 1.

### 14.2 Signing and DMG

There is no Developer ID certificate. Thus Apple cannot notarize the app.

**Use a stable self-signed certificate, not ad-hoc signing.** macOS keeps Automation (Apple Events) approval and Keychain access for a code signature. An ad-hoc signature changes at each build. Then macOS asks you again for iTerm2 control and for the API key in the Keychain after each update. A self-signed certificate keeps the same identity across builds.

1. One time: make a code-signing certificate named `Claude Top Local` in Keychain Access (Certificate Assistant > Create a Certificate, type "Code Signing").
2. Sign the helper, then the app, with `codesign --force --sign "Claude Top Local"`. Sign the helper first.
3. Add `NSAppleEventsUsageDescription` to `Info.plist`.
4. Make the DMG with `hdiutil create`. Include a link to `/Applications`.
5. A script `scripts/release.sh` does steps 2 to 4.

**First start on a Mac.** The DMG gets a quarantine flag when you download it. Gatekeeper then blocks the app, because Apple did not notarize it. On macOS 15 and later, right-click > Open does not bypass this. Do one of these:

- Open the app one time. Then go to System Settings > Privacy & Security, and click **Open Anyway**.
- Or run `xattr -dr com.apple.quarantine "/Applications/Claude Top.app"`.

The README must give these steps. If you build the app on the same Mac, there is no quarantine flag and no block.

**Other Macs.** Other users can install the DMG with the same steps. Their Macs do not trust your certificate, but this does not matter: Gatekeeper treats the app as unnotarized in both cases.

### 14.3 Updates

Version 1 has no auto-update. Sparkle is a possible later addition.

## 15. Tests

| Area | Test |
|---|---|
| State machine | Table tests: lists of events in, expected session states out. Include out-of-order events and a late Jev result. |
| Jev client | Stubbed HTTP responses: success, timeout, HTTP 4xx and 5xx, bad JSON. Check the fallback each time. |
| Thresholds | Probability sets on each side of the red and amber thresholds. Include a split case, for example question 0.3, review 0.3, done 0.4, which must give amber. |
| Installer | Fixture `settings.json` files: empty, with other hooks, with old helper path, invalid JSON. Check the merge and the remove. |
| Helper | Pipe sample payloads to the helper with and without the app running. Check exit code 0 and empty stdout. Check that it finishes in less than 600 ms when the socket is gone. |
| Snapshots | `SNAPSHOT_DIR=<dir> scripts/test.sh --filter Snapshot` draws the panel and the session rows to PNG files for a visual check. |
| End to end | Run a real Claude Code session. Ask for a task that needs a permission (red). Ask for a task that ends with a question (red). Ask for a code change (amber). Ask a plain question, such as "what does this function do" (green). Check the light each time. |

## 16. Milestones

| Milestone | Scope | Result |
|---|---|---|
| M1: Lights | Helper, socket, state machine, three-light panel, session list, menu bar, installer. `Stop` uses the local rule in section 10.6. | The lights and the list work with no network. |
| M2: Jev | Jev classifier, Keychain key, settings, cost display. | `Stop` gives the correct color: red, amber, or green. |
| M3: Polish | Go to session (iTerm2), sound and notification options, open at login, self-signed DMG. | Ready to share. |

## 17. Open questions

There are no open questions.

### 17.1 Closed questions

| Question | Answer (2026-10-15) |
|---|---|
| Color for "ready for review"? | Amber. Review needs human input. "Done" with nothing to review is green. |
| Session list in version 1? | Yes. |
| Developer ID certificate? | No. Use a self-signed certificate (section 14.2). |
| Terminals for "Go to session"? | iTerm2 only (section 9). |
| Can content go to OpenRouter? | Yes. Approved. |

## 18. References

- Claude Code hooks reference: https://code.claude.com/docs/en/hooks.md
- Claude Code hooks guide: https://code.claude.com/docs/en/hooks-guide.md
- Jev on OpenRouter: https://openrouter.ai/docs/guides/community/jev
- Jev tutorial (Decisions API examples): https://openrouter.ai/docs/guides/community/jev-tutorial.md
