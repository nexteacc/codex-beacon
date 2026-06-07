# Codex Beacon Setup Prompt

Copy this whole prompt into Codex on the Mac where you want to install Codex Beacon.

```text
I want you to install and configure this local tool: Codex Beacon.

Goal:
- When Codex requests permission, play a strong macOS system sound and show a Touch Bar state: 🫶 Needs You.
- When Codex finishes a turn, play a softer macOS system sound and show a Touch Bar state: ❤️  Done.
- Idle Touch Bar state should be: ☕ Codex.
- This is only a notifier. Do not try to approve or deny Codex permission requests from the Touch Bar.

Important context:
- I use Codex CLI on macOS.
- I use BetterTouchTool for Touch Bar rendering.
- BetterTouchTool should stay running in the background.
- BetterTouchTool Webserver should listen on 127.0.0.1:12345.
- Do not expose the BetterTouchTool webserver to the LAN or internet.
- Do not overwrite unrelated existing Codex hooks. If ~/.codex/hooks.json exists, merge into it.

Files in this folder:
- hooks/codex-beacon.js
- config.example.env
- install.sh
- btt/Codex Beacon.bttpreset

Please do the following:

1. Inspect the current folder and verify those files exist.

2. Check whether BetterTouchTool is installed.

   Look in:
   - /Applications/BetterTouchTool.app
   - ~/Applications/BetterTouchTool.app

3. Check whether BetterTouchTool webserver is reachable:

   curl -i http://127.0.0.1:12345

   A 404 response is OK. Connection refused means I need to enable BetterTouchTool Webserver.

4. Install the BetterTouchTool preset if it is not already installed.

   The preset is:

   btt/Codex Beacon.bttpreset

   It contains a Touch Bar Shell Script / Task Widget with this fixed UUID:

   C0DEC0DE-BEAC-4001-9000-C0DEC0DEC0DE

   First check whether it already exists:

   osascript -e 'tell application "BetterTouchTool" to get_triggers trigger_uuid "C0DEC0DE-BEAC-4001-9000-C0DEC0DEC0DE"'

   If it does not exist, import the preset:

   osascript -e 'tell application "BetterTouchTool" to import_preset "<absolute path to btt/Codex Beacon.bttpreset>"'

   If automatic import fails, guide me to import the preset manually in BetterTouchTool.

5. Install the tool into:

   ~/.codex/codex-beacon/

   Copy:
   - hooks/codex-beacon.js -> ~/.codex/codex-beacon/codex-beacon.js
   - config.example.env -> ~/.codex/codex-beacon/config.env, but do not overwrite an existing config.env unless I approve.

6. Create this wrapper:

   ~/.codex/codex-beacon/run.sh

   It should:
   - source ~/.codex/codex-beacon/config.env
   - run node ~/.codex/codex-beacon/codex-beacon.js "$@"

7. Edit ~/.codex/codex-beacon/config.env:

   Set:

   CODEX_ATTENTION_BTT_WIDGET_UUID=C0DEC0DE-BEAC-4001-9000-C0DEC0DEC0DE
   CODEX_ATTENTION_BTT_PORT=12345

   Use these defaults unless I ask otherwise:

   CODEX_ATTENTION_IDLE_TEXT='☕ Codex'
   CODEX_ATTENTION_PERMISSION_TEXT='🫶 Needs You'
   CODEX_ATTENTION_DONE_TEXT='❤️  Done'

   CODEX_ATTENTION_IDLE_COLOR=74,48,33,255
   CODEX_ATTENTION_PERMISSION_COLOR=176,54,68,255
   CODEX_ATTENTION_PERMISSION_DIM_COLOR=96,30,40,255
   CODEX_ATTENTION_PERMISSION_BRIGHT_COLOR=198,72,86,255
   CODEX_ATTENTION_DONE_COLOR=68,142,104,255
   CODEX_ATTENTION_DONE_DIM_COLOR=38,96,76,255

   CODEX_ATTENTION_PERMISSION_SOUND=Submarine
   CODEX_ATTENTION_DONE_SOUND=Ping
   CODEX_ATTENTION_PERMISSION_VOLUME=1.0
   CODEX_ATTENTION_DONE_VOLUME=0.45

   CODEX_ATTENTION_PERMISSION_HOLD_MS=3000
   CODEX_ATTENTION_DONE_HOLD_MS=2000

8. Merge these hooks into ~/.codex/hooks.json:

   PermissionRequest:
   command = ~/.codex/codex-beacon/run.sh permission_request

   Stop:
   command = ~/.codex/codex-beacon/run.sh turn_done

   Preserve existing unrelated hooks.

9. Test manually:

   ~/.codex/codex-beacon/run.sh permission_request --debug
   ~/.codex/codex-beacon/run.sh turn_done --debug

   Expected:
   - sound plays
   - BetterTouchTool web response status is 200
   - Touch Bar changes state and then returns to ☕ Codex

10. Tell me to restart Codex CLI/Desktop and run:

   /hooks

   I should review/trust the PermissionRequest and Stop hooks.

11. Final answer should summarize:
   - What was installed
   - Where the config file is
   - How to change emoji/text/sound later
   - How to test again
```
