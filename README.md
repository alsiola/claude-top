# Claude Top

Claude Top is a small macOS app that shows the status of your Claude Code sessions with three lights:

| Light | Meaning |
|---|---|
| Red | A session is blocked on you. It asks a question, asks for permission, or cannot continue. |
| Flashing red | A session stopped because of an API error. For example, the response stopped, your login expired, or you have no credits. |
| Amber | A session finished its work. The work is ready for your review. |
| Green | No session needs you. |

A floating panel shows the lights. A dot in the menu bar shows the same color. Click the panel or the dot to see the session list.

Claude Code hooks send each event to the app. When Claude finishes a turn, the app asks the Jev decision model on OpenRouter which color is correct. See [SPEC.md](SPEC.md) for the full design.

## Requirements

- macOS 14 or later.
- iTerm2, for "Go to session".
- An OpenRouter API key, for the Jev classifier. Without a key, the app uses a simple offline rule.

## Build

You need the Xcode Command Line Tools (`xcode-select --install`). You do not need Xcode.

```sh
scripts/release.sh
```

This makes `dist/Claude Top.app` and `dist/ClaudeTop-0.1.0.dmg`. To build only the app, run `scripts/build-app.sh`.

To run the tests:

```sh
scripts/test.sh
```

## Install

1. Open the DMG. Drag **Claude Top** to **Applications**.
2. Open Claude Top from Applications.
3. If macOS blocks the app, do one of these:
   - Go to **System Settings > Privacy & Security**. Click **Open Anyway**.
   - Or run `xattr -dr com.apple.quarantine "/Applications/Claude Top.app"`.

   macOS blocks the app because Apple did not notarize it. This step is necessary one time only for each DMG download. It is not necessary if you built the app on the same Mac.
4. Claude Top asks to install its Claude Code hooks. Read the change, then click **Install**.
5. Restart your running Claude Code sessions, so that they use the hooks.
6. Optional: Open **Settings** (right-click the menu bar dot). Paste your OpenRouter API key, then click **Save**.

Install the app in `/Applications` before you install the hooks. The hooks contain the path of the app. If you move the app, Claude Top asks to update the hooks at its next start.

## Use

| Action | How |
|---|---|
| See all sessions | Click the light panel or the menu bar dot. |
| Go to a session in iTerm2 | Click its row. If the row is red or amber, the click also sets it to green. |
| Go to a session and keep its color | Right-click the row, then select **Go to Session**. |
| Clear red or amber without going to the tab | Right-click the row, then select **Clear (Set to Green)**. |
| Move the light panel | Drag it. |
| Open the menu | Right-click the menu bar dot, or click `…` in the session list. |

Each row shows the iTerm2 tab title (the conversation topic that Claude Code sets), the reason for its color, and the folder and tab number. A gray row with "No events yet" is a Claude process that has sent no hook events. For example, it started before you installed the hooks. Restart that session to get its status.

The first time that you open the list, macOS asks if Claude Top can control iTerm2. Click **OK**. Without this permission, the rows show no tab titles, and a click cannot go to the tab.

## Hooks

The installer adds one entry to `~/.claude/settings.json` for each of these events: `SessionStart`, `SessionEnd`, `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `PostToolUseFailure`, `PermissionRequest`, `Notification`, `Stop`, and `StopFailure`.

Each entry runs the helper in the app bundle:

```json
{
  "type": "command",
  "command": "'/Applications/Claude Top.app/Contents/MacOS/claude-top-hook'",
  "async": true,
  "timeout": 5
}
```

The installer:

- Does not change your other hooks or settings.
- Keeps the order of the keys in the file.
- Saves a backup next to the file before each change (`settings.json.claude-top-backup-<time>`).
- Writes through a symbolic link to the real file, if `settings.json` is a link.

To remove the hooks, right-click the menu bar dot and select **Remove Hooks…**. This removes only the Claude Top entries.

The helper sends events to the app through a socket at `~/Library/Application Support/ClaudeTop/hook.sock`. Only your user can open it. If the app is not running, the helper does nothing. The helper always exits with code 0, so Claude Code never shows a hook error.

## Webhook

Claude Top can send each state change to one URL. For example, a Home Assistant automation can show the light color on a lamp.

1. Open **Settings**.
2. In **Webhook**, type the URL. Optional: type headers, one `Name: Value` on each line (for example `Authorization: Bearer <token>`).
3. Click **Save**, then click **Send Test**. Settings shows the result of the last send.
4. Turn on **Send state changes to a webhook**.

The URL and the headers are in the macOS Keychain. To delete them, save an empty URL.

Plain `http://` is possible only for local hosts (`.local` names and IP addresses). Other hosts must use `https://`. The first time that the app sends to a local host, macOS can ask for local network access. Click **Allow**.

### Events

Each event is one `POST` with a JSON body. The `type` field tells which event it is. All events have these fields:

| Field | Value |
|---|---|
| `type` | `light.changed`, `session.changed`, `session.ended`, or `test` |
| `timestamp` | ISO 8601 time, for example `2026-10-15T09:30:00Z` |
| `light` | The overall light after the change: `red`, `amber`, `green`, or `off` |
| `red` | The number of red sessions |
| `amber` | The number of amber sessions |

Some events have more fields:

| `type` | When | More fields |
|---|---|---|
| `light.changed` | The overall light changes. Also at app start. | `previous`: the old light |
| `session.changed` | A session gets a new state, or a new session starts. | `session`, `previous`: the old state, or `null` for a new session |
| `session.ended` | A session ends, its process stops, or you remove it. | `session` |
| `test` | You click **Send Test**. | None |

The `session` object has `id`, `project`, `cwd`, `state` (`working`, `idle`, `review`, `attention`, or `failed`), `color` (`red`, `amber`, or `green`), and `reason`.

Example:

```json
{
  "type": "session.changed",
  "timestamp": "2026-10-15T09:30:00Z",
  "light": "red",
  "red": 1,
  "amber": 0,
  "previous": "working",
  "session": {
    "id": "6f1c…",
    "project": "api-server",
    "cwd": "/Users/me/Code/api-server",
    "state": "attention",
    "color": "red",
    "reason": "Permission: Bash"
  }
}
```

One change can send more than one event. The app sends them in order, one at a time. If a send fails, the app does not try again.

### Example: Home Assistant lamp

This automation sets a lamp to the color of the light. It uses only the `light` field, so all event types work. Use a long random webhook ID, because the ID is the secret.

```yaml
alias: Claude Top lamp
mode: restart
triggers:
  - trigger: webhook
    webhook_id: claude-top-REPLACE-WITH-RANDOM-ID
    allowed_methods: [POST]
    local_only: true
actions:
  - choose:
      - conditions: "{{ trigger.json.light == 'off' }}"
        sequence:
          - action: light.turn_off
            target:
              entity_id: light.desk_lamp
    default:
      - action: light.turn_on
        target:
          entity_id: light.desk_lamp
        data:
          rgb_color: "{{ {'red': [255, 0, 0], 'amber': [255, 140, 0], 'green': [0, 255, 0]}[trigger.json.light] }}"
```

In Claude Top, set the URL to `http://homeassistant.local:8123/api/webhook/claude-top-REPLACE-WITH-RANDOM-ID`. A Home Assistant webhook needs no headers.

## Privacy

With Jev on, the last message of each Claude turn goes to OpenRouter (up to the last 4,000 characters). Nothing else goes out: no transcript, no file contents, no tool inputs. To stop this, turn off **Use Jev to classify Stop events** in Settings. The app then uses the offline rule:

- A `?` in the last 300 characters gives red.
- All other messages give amber.

The API key is in the macOS Keychain.

With the webhook on, the project name, folder path, state, and reason of each session go to the webhook URL. The webhook is off by default.

## Signing certificate

The build script signs the app with a certificate named `Claude Top Local`, if one is in your keychain. If not, it uses ad-hoc signing.

With ad-hoc signing, the signature changes at each build. macOS then asks again for iTerm2 control and for Keychain access after each new build. A self-signed certificate prevents this. To make one (one time only):

1. Open **Keychain Access**.
2. Select **Keychain Access > Certificate Assistant > Create a Certificate…**.
3. Name: `Claude Top Local`. Identity Type: **Self Signed Root**. Certificate Type: **Code Signing**.
4. Click **Create**.

Then build again. To use a different certificate, set `SIGN_IDENTITY`:

```sh
SIGN_IDENTITY="My Certificate" scripts/release.sh
```

## Troubleshooting

| Problem | Do this |
|---|---|
| No sessions show | Make sure the hooks are installed (Settings > Claude Code hooks). Restart the Claude Code session. |
| A session stays red after you answered | Click its row. |
| A message gets the wrong color | Add it with the correct state to `Tests/Fixtures/stop-messages.json`. Run `swift run -c release claude-top-eval` to measure the labels. |
| Sessions do not go away | The app removes a session when its Claude Code process stops. The check runs every 30 seconds. |
| Jev errors | Settings shows the last error. Check the API key and the model ID. |
| Webhook says "macOS blocks local network access" | Go to **System Settings > Privacy & Security > Local Network**. Turn on **Claude Top**. Then click **Send Test** again. |
| Webhook says "Could not connect to the server" | Make sure the host and the port are correct. For example, Home Assistant behind a proxy can use port 80, not 8123. |
| You want helper logs | Start Claude Code with `CLAUDE_TOP_DEBUG=1`. The helper writes to `~/Library/Logs/ClaudeTop/hook.log`. |

## Project layout

| Path | Contents |
|---|---|
| `Sources/ClaudeTopCore` | State machine, Jev client, offline rule, hook installer, JSON parser, webhook events. No UI. |
| `Sources/ClaudeTop` | The app: socket server, light panel, menu bar, session list, settings. |
| `Sources/claude-top-hook` | The helper that Claude Code runs for each event. |
| `Tests` | Unit tests, and snapshot tests that draw the views to PNG files. |
| `scripts` | Build, release, test, and icon scripts. |
