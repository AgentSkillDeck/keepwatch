#!/usr/bin/env python3
"""Builds video/tour/index.html (a HyperFrames composition) from the narration's
timeline.json and captions.srt, so scene cuts follow the voice exactly.

Usage: python3 video/build.py   (after rendering video/audio/tour.audio.md to video/audio/final)
"""
import html
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent
AUDIO = ROOT / "audio" / "final"
OUT = ROOT / "tour" / "index.html"

timeline = json.loads((AUDIO / "timeline.json").read_text())
duration = round(float(timeline["duration_s"]) + 1.2, 2)
starts = [float(s["start"]) for s in timeline["scenes"]]
names = [s["name"] for s in timeline["scenes"]]


def window(i):
    """Scene i runs from a little before its first word to the next scene's start."""
    a = 0.0 if i == 0 else starts[i] - 0.25
    b = duration if i == len(starts) - 1 else starts[i + 1] - 0.25
    return round(a, 3), round(b - a, 3)


def srt_cues(path):
    def secs(t):
        h, m, rest = t.split(":")
        s, ms = rest.split(",")
        return int(h) * 3600 + int(m) * 60 + int(s) + int(ms) / 1000

    cues = []
    for block in re.split(r"\n\s*\n", path.read_text().strip()):
        lines = block.strip().splitlines()
        if len(lines) >= 3 and "-->" in lines[1]:
            a, b = (x.strip() for x in lines[1].split("-->"))
            cues.append((secs(a), secs(b), " ".join(lines[2:])))
    return cues


# Screenshot scenes: (image, title, bullets, highlights as (x, y, w, h) in image pixels).
# Dashboard images are 1520 x 1440; the menu is 680 wide.
SHOTS = {
    "Awake": ("dashboard-dark.png", "Stay awake, your way",
              ["1 h, 3 h, a day, forever", "Or any custom time", "Or only while agents run"],
              [(72, 745, 1376, 192), (72, 952, 1376, 70)]),
    "Agents": ("tab-agents-dark.png", "Every agent session",
               ["Claude Code, Codex, Gemini and more", "Working or gone quiet", "Stop any session in one click"],
               [(72, 700, 1376, 265), (1130, 805, 300, 130)]),
    "Lid": ("tab-lid-dark.png", "Work with the lid shut",
            ["Sleeps by itself when time is up", "1, 3, 6 or 12 hours", "On battery above 20%"],
            [(60, 770, 1400, 80), (60, 1135, 1400, 70)]),
    "Privacy": ("tab-privacy-dark.png", "Mic and camera, watched",
                ["See which app is listening", "Mute the mic with one switch", "History stays on your Mac"],
                [(60, 700, 1400, 140), (60, 1120, 1400, 215)]),
    "Security": ("tab-security-dark.png", "Security at a glance",
                 ["Firewall and FileVault", "Gatekeeper and SIP", "AirDrop set to Everyone? You'll see it"],
                 [(60, 705, 1400, 300), (60, 985, 1400, 60)]),
    "Your way": ("dashboard-all-tiles-dark.png", "Make it yours",
                 ["Pick the tiles you want", "Handy Mac settings, one switch"],
                 [(72, 230, 1376, 400)]),
}
PAIRS = {
    "Battery and apps": (("tab-power-dark.png", [(60, 640, 1400, 350), (60, 1090, 1400, 250)]),
                         ("tab-ports-dark.png", [(60, 640, 1400, 410)]),
                         "Battery and memory",
                         ["Battery health over time", "Quit the apps using the most memory", "Stop a forgotten dev server"]),
}

TEAL = "#2EE6CF"
IMG_H = 880  # on-screen height of a dashboard screenshot


def bullets(items, sid):
    return "".join(f'<li class="b" id="{sid}-b{k}"><span class="dot"></span>{html.escape(t)}</li>'
                   for k, t in enumerate(items))


def shot_window(sid, img, boxes, w_px, h_px, left, top, height):
    scale = height / h_px
    width = round(w_px * scale)
    hl = "".join(
        f'<div class="hl" id="{sid}-h{k}" style="left:{round(x*scale)}px;top:{round(y*scale)}px;'
        f'width:{round(w*scale)}px;height:{round(h*scale)}px"></div>'
        for k, (x, y, w, h) in enumerate(boxes))
    return (f'<div class="win" id="{sid}-win" style="left:{left}px;top:{top}px;width:{width}px;height:{height}px">'
            f'<img src="assets/{img}" alt="" style="width:{width}px;height:{height}px" />{hl}</div>')


scenes_html = []
anim = []

for i, name in enumerate(names):
    start, dur = window(i)
    sid = f"s{i}"
    body = ""
    if name == "Intro":
        body = f"""
        <div class="intro">
          <img id="{sid}-icon" class="icon" src="assets/icon.png" alt="" />
          <h1 id="{sid}-title">Keepwatch</h1>
          <p id="{sid}-tag">Keep your Mac awake for AI agents.<span class="br"></span>Keep watch on your mic and camera.</p>
        </div>
        <div class="win menu" id="{sid}-win" style="left:1300px;top:70px;width:440px;height:806px">
          <img src="assets/menu-dark.png" alt="" style="width:440px;height:806px" /></div>"""
        anim += [
            f'tl.fromTo("#{sid}-icon",{{scale:0.6,opacity:0}},{{scale:1,opacity:1,duration:0.9,ease:"back.out(1.6)"}},{start+0.2})',
            f'tl.fromTo("#{sid}-title",{{y:40,opacity:0}},{{y:0,opacity:1,duration:0.8,ease:"power3.out"}},{start+0.6})',
            f'tl.fromTo("#{sid}-tag",{{y:30,opacity:0}},{{y:0,opacity:1,duration:0.8,ease:"power3.out"}},{start+1.1})',
            f'tl.fromTo("#{sid}-win",{{x:160,opacity:0,rotationY:-18}},{{x:0,opacity:1,rotationY:-8,duration:1.4,ease:"power3.out"}},{start+1.6})',
            f'tl.to("#{sid}-win",{{rotationY:-3,y:-14,duration:{max(dur-3.2, 1):.2f},ease:"sine.inOut"}},{start+3.0})',
        ]
    elif name in SHOTS:
        img, title, items, boxes = SHOTS[name]
        body = f"""
        <div class="copy"><div class="kicker" id="{sid}-k">{html.escape(name if name != "Your way" else "Customize")}</div>
          <h2 id="{sid}-t">{html.escape(title)}</h2><ul>{bullets(items, sid)}</ul></div>
        {shot_window(sid, img, boxes, 1520, 1440, 880, 100, IMG_H)}"""
    elif name in PAIRS:
        (img_a, box_a), (img_b, box_b), title, items = PAIRS[name]
        body = f"""
        <div class="copy"><div class="kicker" id="{sid}-k">Battery and apps</div>
          <h2 id="{sid}-t">{html.escape(title)}</h2><ul>{bullets(items, sid)}</ul></div>
        {shot_window(sid + "a", img_a, box_a, 1520, 1440, 760, 150, 720)}
        {shot_window(sid + "b", img_b, box_b, 1520, 1440, 1100, 250, 720)}"""
    elif name == "Terminal":
        lines = [
            ("cmd", "keepwatch awake --for 3h"),
            ("out", "Keeping your Mac awake for 3 h"),
            ("cmd", "keepwatch agents"),
            ("out", "Claude Code  41201  website      working"),
            ("out", "Codex        42010  mobile-app   working"),
            ("cmd", "keepwatch run -- npm test"),
            ("out", "Awake while npm test runs"),
        ]
        rows = "".join(
            f'<div class="tl {k}" id="{sid}-l{j}">{"<span class=p>$</span> " if k == "cmd" else ""}{html.escape(t)}</div>'
            for j, (k, t) in enumerate(lines))
        body = f"""
        <div class="copy"><div class="kicker" id="{sid}-k">Command line</div>
          <h2 id="{sid}-t">Your agent can use it too</h2>
          <ul>{bullets(["A keepwatch command for the terminal", "A skill for coding agents"], sid)}</ul></div>
        <div class="term" id="{sid}-win"><div class="bar"><i></i><i></i><i></i><span>Terminal</span></div>
          <div class="screen">{rows}</div></div>"""
        for j, (k, _) in enumerate(lines):
            at = start + 0.8 + j * min(0.75, (dur - 1.5) / len(lines))
            anim.append(f'tl.fromTo("#{sid}-l{j}",{{opacity:0,x:-12}},{{opacity:1,x:0,duration:0.35,ease:"power2.out"}},{at:.2f})')
        anim.append(f'tl.fromTo("#{sid}-win",{{y:40,opacity:0}},{{y:0,opacity:1,duration:0.8,ease:"power3.out"}},{start+0.2})')
    elif name == "Outro":
        body = f"""
        <div class="intro outro">
          <img id="{sid}-icon" class="icon" src="assets/icon.png" alt="" />
          <h1 id="{sid}-title">Keepwatch</h1>
          <div class="pills" id="{sid}-pills"><span>Free</span><span>Open source</span><span>Signed and notarized</span><span>Intel and Apple silicon</span></div>
          <p class="url" id="{sid}-url">github.com/AgentSkillDeck/keepwatch</p>
          <p class="credit" id="{sid}-credit">Music: “Soft Corporate” by MusicLFiles, CC BY 4.0 · Voice: Supertonic, generated on device · Screens show demo data</p>
        </div>"""
        anim += [
            f'tl.fromTo("#{sid}-icon",{{scale:0.6,opacity:0}},{{scale:1,opacity:1,duration:0.9,ease:"back.out(1.6)"}},{start+0.2})',
            f'tl.fromTo("#{sid}-title",{{y:40,opacity:0}},{{y:0,opacity:1,duration:0.8,ease:"power3.out"}},{start+0.5})',
            f'tl.fromTo("#{sid}-pills span",{{y:24,opacity:0}},{{y:0,opacity:1,duration:0.5,stagger:0.18,ease:"power3.out"}},{start+1.0})',
            f'tl.fromTo("#{sid}-url",{{opacity:0}},{{opacity:1,duration:0.8}},{start+2.0})',
            f'tl.fromTo("#{sid}-credit",{{opacity:0}},{{opacity:0.7,duration:0.8}},{start+2.6})',
        ]

    # Shared motion for scenes with copy and screenshots.
    if name in SHOTS or name in PAIRS or name == "Terminal":
        anim += [
            f'tl.fromTo("#{sid}-k",{{y:20,opacity:0}},{{y:0,opacity:1,duration:0.5,ease:"power3.out"}},{start+0.15})',
            f'tl.fromTo("#{sid}-t",{{y:30,opacity:0}},{{y:0,opacity:1,duration:0.7,ease:"power3.out"}},{start+0.3})',
            f'tl.fromTo("#{sid} .b",{{x:-24,opacity:0}},{{x:0,opacity:1,duration:0.5,stagger:{min(1.4, dur/5):.2f},ease:"power3.out"}},{start+0.9})',
        ]
    wins = [sid] if name in SHOTS else ([sid + "a", sid + "b"] if name in PAIRS else [])
    boxes = SHOTS[name][3] if name in SHOTS else []
    for w_i, w in enumerate(wins):
        anim += [
            f'tl.fromTo("#{w}-win",{{y:60,opacity:0,scale:0.96}},{{y:0,opacity:1,scale:1,duration:0.9,ease:"power3.out"}},{start+0.2+w_i*0.35})',
            f'tl.to("#{w}-win",{{scale:1.035,y:-10,duration:{max(dur-1.3, 1):.2f},ease:"sine.inOut"}},{start+1.1+w_i*0.35})',
        ]
        n = len(boxes) if name in SHOTS else len((PAIRS[name][0] if w_i == 0 else PAIRS[name][1])[1])
        for k in range(n):
            at = start + 1.6 + w_i * 1.2 + k * max(1.2, (dur - 3) / max(n, 1))
            anim.append(f'tl.fromTo("#{w}-h{k}",{{opacity:0,scale:1.04}},{{opacity:1,scale:1,duration:0.5,ease:"power2.out"}},{at:.2f})')

    scenes_html.append(f'<section class="clip scene" id="{sid}" data-start="{start}" data-duration="{dur}" '
                       f'data-track-index="1">{body}</section>')

caps = []
for j, (a, b, text) in enumerate(srt_cues(AUDIO / "captions.srt")):
    caps.append(f'<div class="clip cap" id="c{j}" data-start="{a:.3f}" data-duration="{max(b - a, 0.3):.3f}" '
                f'data-track-index="2"><span>{html.escape(text)}</span></div>')

page = f"""<!doctype html>
<html lang="en">
  <head>
    <meta charset="UTF-8" />
    <meta name="viewport" content="width=1920, height=1080" />
    <script src="https://cdn.jsdelivr.net/npm/gsap@3.14.2/dist/gsap.min.js"></script>
    <style>
      * {{ margin: 0; padding: 0; box-sizing: border-box; }}
      html, body {{ width: 1920px; height: 1080px; overflow: hidden; background: #08100f; }}
      #root {{ position: relative; width: 100%; height: 100%; overflow: hidden; color: #eef7f5;
              font-family: -apple-system, BlinkMacSystemFont, system-ui, sans-serif; }}
      .bg {{ position: absolute; inset: 0;
             background: radial-gradient(1100px 700px at 75% 40%, rgba(46,230,207,0.16), transparent 70%),
                         radial-gradient(900px 600px at 10% 90%, rgba(77,128,242,0.12), transparent 70%),
                         linear-gradient(160deg, #0b1716, #070b0b); }}
      .grid {{ position: absolute; inset: 0; opacity: 0.18;
               background-image: linear-gradient(rgba(255,255,255,0.06) 1px, transparent 1px),
                                 linear-gradient(90deg, rgba(255,255,255,0.06) 1px, transparent 1px);
               background-size: 64px 64px; }}
      .scene {{ position: absolute; inset: 0; perspective: 1600px; }}
      .copy {{ position: absolute; left: 120px; top: 250px; width: 640px; }}
      .kicker {{ color: {TEAL}; font-size: 26px; font-weight: 700; letter-spacing: 0.14em; text-transform: uppercase; }}
      h2 {{ font-size: 72px; line-height: 1.05; font-weight: 800; letter-spacing: -0.02em; margin: 18px 0 40px; }}
      ul {{ list-style: none; }}
      .b {{ display: flex; align-items: center; gap: 18px; font-size: 34px; color: #cfe3df; margin: 0 0 22px; }}
      .dot {{ width: 14px; height: 14px; border-radius: 50%; background: {TEAL}; box-shadow: 0 0 18px {TEAL}; flex: none; }}
      .win {{ position: absolute; border-radius: 26px; overflow: hidden; background: #1e1e1e;
              box-shadow: 0 40px 120px rgba(0,0,0,0.6), 0 0 0 1px rgba(255,255,255,0.08); }}
      .win img {{ display: block; }}
      .hl {{ position: absolute; border-radius: 16px; border: 4px solid {TEAL};
             box-shadow: 0 0 0 6px rgba(46,230,207,0.18), 0 0 40px rgba(46,230,207,0.45); }}
      .intro {{ position: absolute; left: 140px; top: 0; bottom: 0; width: 1100px; display: flex;
                flex-direction: column; justify-content: center; }}
      .icon {{ width: 190px; height: 190px; border-radius: 44px; box-shadow: 0 30px 80px rgba(46,230,207,0.25); }}
      h1 {{ font-size: 150px; font-weight: 800; letter-spacing: -0.03em; margin: 30px 0 18px; }}
      .intro p {{ font-size: 44px; line-height: 1.35; color: #cfe3df; }}
      .br {{ display: block; }}
      .outro {{ left: 0; right: 0; width: auto; align-items: center; text-align: center; }}
      .pills {{ display: flex; gap: 18px; margin: 10px 0 40px; }}
      .pills span {{ display: block; font-size: 30px; font-weight: 600; padding: 14px 28px; border-radius: 999px;
                     background: rgba(46,230,207,0.12); border: 2px solid rgba(46,230,207,0.5); color: #dffaf6; }}
      .outro .url {{ font-size: 48px; font-weight: 700; color: {TEAL}; }}
      .outro .credit {{ position: absolute; bottom: 150px; font-size: 22px; color: #9fb5b1; }}
      .term {{ position: absolute; left: 860px; top: 230px; width: 940px; border-radius: 22px; overflow: hidden;
               background: #0d1111; box-shadow: 0 40px 120px rgba(0,0,0,0.6), 0 0 0 1px rgba(255,255,255,0.1); }}
      .term .bar {{ display: flex; align-items: center; gap: 12px; height: 56px; padding: 0 22px; background: #1b2221; }}
      .term .bar i {{ display: block; width: 16px; height: 16px; border-radius: 50%; background: #ff5f57; }}
      .term .bar i:nth-child(2) {{ background: #febc2e; }}
      .term .bar i:nth-child(3) {{ background: #28c840; }}
      .term .bar span {{ margin-left: 14px; color: #8fa5a1; font-size: 22px; }}
      .screen {{ padding: 34px 40px 40px; font-family: ui-monospace, Menlo, monospace; font-size: 30px; line-height: 1.75; }}
      .tl {{ white-space: pre; }}
      .tl.cmd {{ color: #f2fbf9; }}
      .tl.out {{ color: #8fd9cd; }}
      .p {{ color: {TEAL}; font-weight: 700; }}
      .cap {{ position: absolute; left: 0; right: 0; bottom: 46px; display: flex; justify-content: center; }}
      .cap span {{ display: block; max-width: 1500px; padding: 12px 28px; border-radius: 14px; text-align: center;
                   background: rgba(0,0,0,0.62); color: #ffffff; font-size: 34px; line-height: 1.3; font-weight: 500; }}
    </style>
  </head>
  <body>
    <div id="root" data-composition-id="main" data-start="0" data-duration="{duration}" data-width="1920" data-height="1080">
      <div class="clip bg" id="bg" data-start="0" data-duration="{duration}" data-track-index="0"><div class="grid"></div></div>
      {"".join(scenes_html)}
      {"".join(caps)}
      <audio id="voice" src="assets/tour.mp3" data-start="0" data-duration="{duration}" data-track-index="3"></audio>
    </div>
    <script>
      const tl = gsap.timeline({{ paused: true }});
      {";".join(anim)};
      window.__timelines["main"] = tl;
      tl.seek(0);
    </script>
  </body>
</html>
"""
OUT.write_text(page)
print(f"wrote {OUT} ({duration} s, {len(names)} scenes, {len(caps)} captions)")
