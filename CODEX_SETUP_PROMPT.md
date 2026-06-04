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

Please do the following:

1. Inspect the current folder and verify those files exist.

2. Check whether BetterTouchTool webserver is reachable:

   curl -i http://127.0.0.1:12345

   A 404 response is OK. Connection refused means I need to enable BetterTouchTool Webserver.

3. Ask me for my BetterTouchTool Touch Bar widget UUID if it is not already known.

   If I have not created the widget yet, guide me:
   - Open BetterTouchTool.
   - Go to Touch Bar.
   - Add a global Touch Bar Widget.
   - Choose "Shell Script / Task Widget".
   - Set its script to:

     echo${IFS}☕Codex

   - Copy the widget UUID.

4. Install the tool into:

   ~/.codex/codex-beacon/

   Copy:
   - hooks/codex-beacon.js -> ~/.codex/codex-beacon/codex-beacon.js
   - config.example.env -> ~/.codex/codex-beacon/config.env, but do not overwrite an existing config.env unless I approve.

5. Create this wrapper:

   ~/.codex/codex-beacon/run.sh

   It should:
   - source ~/.codex/codex-beacon/config.env
   - run node ~/.codex/codex-beacon/codex-beacon.js "$@"

6. Edit ~/.codex/codex-beacon/config.env:

   Set:

   CODEX_ATTENTION_BTT_WIDGET_UUID=<my copied UUID>
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

7. Merge these hooks into ~/.codex/hooks.json:

   PermissionRequest:
   command = ~/.codex/codex-beacon/run.sh permission_request

   Stop:
   command = ~/.codex/codex-beacon/run.sh turn_done

   Preserve existing unrelated hooks.

8. Test manually:

   ~/.codex/codex-beacon/run.sh permission_request --debug
   ~/.codex/codex-beacon/run.sh turn_done --debug

   Expected:
   - sound plays
   - BetterTouchTool web response status is 200
   - Touch Bar changes state and then returns to ☕ Codex

9. Tell me to restart Codex CLI and run:

   /hooks

   I should review/trust the PermissionRequest and Stop hooks.

10. Final answer should summarize:
   - What was installed
   - Where the config file is
   - How to change emoji/text/sound later
   - How to test again
```
