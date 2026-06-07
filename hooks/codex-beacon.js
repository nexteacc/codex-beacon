#!/usr/bin/env node
"use strict";

const { spawn, spawnSync } = require("node:child_process");
const http = require("node:http");
const fs = require("node:fs");

const eventName = process.argv[2] || "unknown";
const DEBUG = process.argv.includes("--debug") || process.env.CODEX_ATTENTION_DEBUG === "1";
const permissionText = process.env.CODEX_ATTENTION_PERMISSION_TEXT || "🫶 Needs You";
const doneText = process.env.CODEX_ATTENTION_DONE_TEXT || "❤️  Done";
const permissionColor = process.env.CODEX_ATTENTION_PERMISSION_COLOR || "176,54,68,255";
const permissionDimColor = process.env.CODEX_ATTENTION_PERMISSION_DIM_COLOR || "96,30,40,255";
const permissionBrightColor = process.env.CODEX_ATTENTION_PERMISSION_BRIGHT_COLOR || "198,72,86,255";
const doneColor = process.env.CODEX_ATTENTION_DONE_COLOR || "68,142,104,255";
const doneDimColor = process.env.CODEX_ATTENTION_DONE_DIM_COLOR || "38,96,76,255";
const permissionHoldMs = readDurationMs("CODEX_ATTENTION_PERMISSION_HOLD_MS", 1700);
const doneHoldMs = readDurationMs("CODEX_ATTENTION_DONE_HOLD_MS", 1440);

const EVENTS = {
  permission_request: {
    title: "Codex needs approval",
    message: "A permission request is waiting.",
    sound: process.env.CODEX_ATTENTION_PERMISSION_SOUND || "Submarine",
    volume: process.env.CODEX_ATTENTION_PERMISSION_VOLUME || process.env.CODEX_ATTENTION_VOLUME || "1.0",
    bttTrigger: process.env.CODEX_ATTENTION_BTT_PERMISSION_TRIGGER || "",
    touchText: permissionText,
    touchColor: permissionColor,
    pulse: scalePulse([
      { text: permissionText, color: permissionColor, holdMs: 520 },
      { text: permissionText, color: permissionDimColor, holdMs: 360 },
      { text: permissionText, color: permissionBrightColor, holdMs: 820 },
    ], permissionHoldMs),
  },
  turn_done: {
    title: "Codex finished",
    message: "The current turn has stopped.",
    sound: process.env.CODEX_ATTENTION_DONE_SOUND || "Ping",
    volume: process.env.CODEX_ATTENTION_DONE_VOLUME || process.env.CODEX_ATTENTION_VOLUME || "0.45",
    bttTrigger: process.env.CODEX_ATTENTION_BTT_DONE_TRIGGER || "",
    touchText: doneText,
    touchColor: doneColor,
    pulse: scalePulse([
      { text: doneText, color: doneColor, holdMs: 540 },
      { text: doneText, color: doneDimColor, holdMs: 900 },
    ], doneHoldMs),
  },
};

const event = EVENTS[eventName] || {
  title: "Codex event",
  message: eventName,
  sound: process.env.CODEX_ATTENTION_DEFAULT_SOUND || "Ping",
  volume: process.env.CODEX_ATTENTION_VOLUME || "0.7",
  bttTrigger: "",
  touchText: "☕ Codex",
  touchColor: "80,160,255,255",
  pulse: [],
};

function log(message) {
  if (DEBUG) {
    console.error(`[codex-beacon] ${message}`);
  }
}

function readDurationMs(name, fallbackMs) {
  const value = Number(process.env[name]);
  if (!Number.isFinite(value) || value < 0) {
    return fallbackMs;
  }

  return value;
}

function scalePulse(steps, totalMs) {
  const currentTotalMs = steps.reduce((sum, step) => sum + Number(step.holdMs || 0), 0);
  if (currentTotalMs <= 0) {
    return steps;
  }

  return steps.map((step) => ({
    ...step,
    holdMs: Math.round((Number(step.holdMs || 0) / currentTotalMs) * totalMs),
  }));
}

function run(command, args, label) {
  log(`running ${label || command}: ${command} ${args.map((arg) => JSON.stringify(arg)).join(" ")}`);

  const result = spawnSync(command, args, {
    stdio: DEBUG ? "inherit" : "ignore",
    timeout: 3000,
  });

  if (result.error) {
    log(`${label || command} error: ${result.error.message}`);
  } else {
    log(`${label || command} exit status: ${result.status}`);
  }

  return result;
}

function runDetached(command, args, label) {
  log(`running ${label || command} detached: ${command} ${args.map((arg) => JSON.stringify(arg)).join(" ")}`);

  try {
    const child = spawn(command, args, {
      detached: true,
      stdio: "ignore",
    });
    child.unref();
    return true;
  } catch (error) {
    log(`${label || command} detached error: ${error.message}`);
    return false;
  }
}

function maybeNotifyMac() {
  if (process.env.CODEX_ATTENTION_MAC_NOTIFICATION !== "1") {
    log("macOS notification disabled; set CODEX_ATTENTION_MAC_NOTIFICATION=1 to enable");
    return;
  }

  const script = String.raw`
function run(argv) {
  ObjC.import("Foundation");
  const notification = $.NSUserNotification.alloc.init;
  notification.setTitle(argv[0]);
  notification.setInformativeText(argv[1]);
  $.NSUserNotificationCenter.defaultUserNotificationCenter.deliverNotification(notification);
}
`;

  run("/usr/bin/osascript", ["-l", "JavaScript", "-e", script, event.title, event.message], "macOS notification");
}

function playSound({ detached = false } = {}) {
  if (process.env.CODEX_ATTENTION_SOUND === "0") {
    log("sound disabled by CODEX_ATTENTION_SOUND=0");
    return;
  }

  const soundPath = process.env.CODEX_ATTENTION_SOUND_PATH || `/System/Library/Sounds/${event.sound}.aiff`;
  if (!fs.existsSync(soundPath)) {
    log(`sound file not found: ${soundPath}`);
    return;
  }

  const args = ["-v", String(event.volume), soundPath];
  if (detached) {
    runDetached("/usr/bin/afplay", args, "sound");
    return;
  }

  run("/usr/bin/afplay", args, "sound");
}

function triggerBetterTouchToolNamedTrigger() {
  if (!event.bttTrigger) return;
  if (!isBetterTouchToolInstalled()) {
    log("BetterTouchTool not found; skipping Touch Bar trigger");
    return;
  }

  const script = `
on run argv
  tell application "BetterTouchTool" to trigger_named (item 1 of argv)
end run
`;

  run("/usr/bin/osascript", ["-e", script, event.bttTrigger], "BetterTouchTool named trigger");
}

function isBetterTouchToolInstalled() {
  return [
    "/Applications/BetterTouchTool.app",
    `${process.env.HOME || ""}/Applications/BetterTouchTool.app`,
  ].some((path) => path && fs.existsSync(path));
}

function bttWebRequest(path) {
  const port = Number(process.env.CODEX_ATTENTION_BTT_PORT || "12345");

  return new Promise((resolve) => {
    log(`BTT web request: http://127.0.0.1:${port}${path}`);
    const req = http.get(
      {
        host: "127.0.0.1",
        port,
        path,
        timeout: 800,
      },
      (res) => {
        log(`BTT web response status: ${res.statusCode}`);
        res.resume();
        res.on("end", resolve);
      }
    );

    req.on("error", (error) => {
      log(`BTT web request error: ${error.message}`);
      resolve();
    });
    req.on("timeout", () => {
      log("BTT web request timed out");
      req.destroy();
      resolve();
    });
  });
}

async function pulseBetterTouchToolWidget() {
  const uuid = process.env.CODEX_ATTENTION_BTT_WIDGET_UUID;
  if (!uuid) {
    log("CODEX_ATTENTION_BTT_WIDGET_UUID not set; skipping Touch Bar widget pulse");
    return;
  }

  const resetColor = process.env.CODEX_ATTENTION_IDLE_COLOR || "20,20,20,255";
  const resetText = process.env.CODEX_ATTENTION_IDLE_TEXT || "☕ Codex";
  const durationMs = Number(process.env.CODEX_ATTENTION_PULSE_MS || "900");

  const updatePath = (text, color) =>
    `/update_touch_bar_widget/?uuid=${encodeURIComponent(uuid)}&text=${encodeURIComponent(text)}&background_color=${encodeURIComponent(color)}`;

  const sequence = process.env.CODEX_ATTENTION_SIMPLE_PULSE === "1"
    ? [{ text: event.touchText, color: event.touchColor, holdMs: durationMs }]
    : event.pulse.length > 0
      ? event.pulse
      : [{ text: event.touchText, color: event.touchColor, holdMs: durationMs }];

  for (const step of sequence) {
    await bttWebRequest(updatePath(step.text, step.color));
    await new Promise((resolve) => setTimeout(resolve, Number(step.holdMs || durationMs)));
  }

  await bttWebRequest(updatePath(resetText, resetColor));
}

async function main() {
  log(`event: ${eventName}`);
  maybeNotifyMac();
  triggerBetterTouchToolNamedTrigger();
  playSound({ detached: true });
  await pulseBetterTouchToolWidget();
  log("done");
}

main().catch((error) => {
  log(`fatal error: ${error.message}`);
  process.exitCode = 0;
});
