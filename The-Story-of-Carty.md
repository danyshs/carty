# The Story of Carty

*Written for someone who just finished first-year CS — you know what a loop and an `if` are, but you haven't met all the jargon yet. Every technical word here gets explained in plain English the first time it shows up.*

---

## What Carty is trying to do

Imagine you walk around your apartment filming a video on your phone. Carty's job is to turn that video into a clean, top-down map of the place — the kind you'd see in a Dungeons & Dragons game, where you're looking straight down at the rooms, walls, and doors from above.

Two rules make Carty unusual, and they shape the *entire* story:

1. **Everything runs on the phone.** No sending your video to a server somewhere. The map is built on the device, in your pocket, even with airplane mode on.
2. **The AI is *not* the artist.** Carty does have an on-device AI (a language model called Gemma), but it is only allowed to *fix small mistakes* in a map that ordinary, predictable math has already drawn. The AI never draws the map itself. This rule turns out to be the single most important lesson I learned — and I learned it the hard way.

The whole story below takes place over a remarkably short, intense window: the dramatic, well-documented part runs from **June 11 to June 22, 2026** — about eleven days. Some foundational pieces were built quietly *before* that. So when you see how much happens, remember: this is roughly a week and a half of focused work.

---

## Chapter 0: The foundations (before June 2026)

Before the dramatic stuff, a few solid building blocks already existed and were tested. Think of these as the workshop being set up before the real project starts:

- **A bridge between two programming languages.** Carty's interface is written in **Dart** (the language behind Flutter, a toolkit for building phone apps). But the heavy number-crunching is written in **C++** (a faster, lower-level language). To let Dart call C++ code, I used a mechanism called **FFI** ("Foreign Function Interface") — basically a translator that lets one language phone up the other and pass data back and forth. All of Carty's Dart-to-C++ talking happens through one carefully guarded file so the "border crossing" stays safe.

- **A version-control system for maps.** You may know **Git**, the tool that tracks every change to your code and lets you undo, branch, and merge. I built a tiny Git *for maps*. Every version of a map gets a unique fingerprint (using **SHA-256**, a standard function that turns any data into a fixed 64-character code — change one pixel and the fingerprint changes completely). This means you can undo edits, keep different versions, and later even share maps with other people.

- **A way to pull still frames out of a video**, and an early "inference layer" — the plumbing that would eventually feed pictures to the AI and read its answers back.

These worked. The drama was about everything built *on top* of them.

---

## Chapter 1: The week everything broke and got rebuilt (June 11–12)

### June 11 — "None of the buttons work"

The app launched, but every button seemed dead, and one of them crashed with a confusing error. After a lot of digging, the cause turned out to be a classic beginner-to-intermediate trap in Flutter: a piece of the app was set up *above* the part of the program that knows how to open pop-up dialogs, so when a button tried to open a dialog, the app looked "upward" for the right machinery and never found it. The fix was to rearrange which piece sat where. (If you've ever had a variable that was "out of scope" and unreachable, it's the same flavor of bug.)

The same day, a sneaky storage problem was caught: the build tool was secretly copying the *entire* multi-gigabyte project into a hidden folder every single time it ran. Sixteen copies had piled up — about **39 GB** of wasted disk. Fixing it reclaimed 36 GB.

### June 12 — The day Carty's whole strategy changed

This is the most important day in the story.

The *original* plan was: feed the AI a video frame, ask the AI to draw the map for that frame, repeat. It sounded reasonable. But when I actually ran it on a real frame, three things went catastrophically wrong:

1. **The AI made things up.** Shown a real picture of a room, it confidently produced **41 identical "wall" entries** arranged in a neat fake grid that had *nothing to do with the actual room*. It didn't read the picture; it invented a generic-looking answer.
2. **It wrote too much and got cut off.** It blew past its size limit, so the output ended mid-sentence and couldn't even be read back properly.
3. **It was painfully slow — about 50 seconds *per frame*.** A video has dozens of frames per second. This was never going to work on a phone.

The conclusion was decisive: **an AI is the wrong tool for drawing geometry.** Drawing the actual shape of a room is a job for precise, predictable math. The AI's real talent — judgment, like "is that fuzzy thing a doorway or a gap in the wall?" — should only be used to *touch up* a map the math already built.

This is "the pivot," and it became the law of the project: **the algorithm is the cartographer; the AI is the editor.**

On the same day, I also made a clean-up decision: **Carty would never again run as a desktop app.** Running it on a PC had been a distraction that exercised a flow the real phone product didn't even use. From now on, testing would happen on a fixed "ladder" (more on that in a moment).

---

## Chapter 2: Getting onto a real phone (June 12–15)

With the new plan, I needed to prove the basics actually work on Android hardware. I climbed what I call the **test ladder** — three rungs, each more realistic than the last:

1. **The plain computer ("host").** Fast, no graphics, good for running automated tests.
2. **The Android emulator.** A fake phone running on the computer — the first time you can actually *see* the app's screen.
3. **A real physical phone** (a OnePlus 8 Pro). The only place where real camera tracking, real speed, real battery heat, and real memory limits show up.

**June 14:** The app ran on the emulator. The home screen was redesigned to look like a real product — one friendly "Make a map" button — with all the developer tools hidden behind a secret long-press on the title.

**June 14–15:** On the real OnePlus phone, three crucial things were proven to work:

- **ARCore tracking.** *ARCore* is Google's package for **augmented reality**. The piece Carty uses is called **VIO** ("Visual-Inertial Odometry"). In plain terms: it takes the camera image plus the phone's motion sensors and continuously figures out **where the phone is and which way it's pointing** as you move — all on the device, offline. That position-and-orientation reading is called a **pose**. Pose is the missing ingredient that makes a map possible: it's how Carty knows that *this* photo and *that* photo are looking at two different corners of the same room.
- **Pulling frames out of a video on the phone**, using Android's built-in `MediaMetadataRetriever` (a standard tool that grabs a picture from a video at a given timestamp).
- **A live pose test** that confirmed the phone really could report its 6-direction movement (left/right, up/down, forward/back, plus tilt) — 35 good readings out of 60 while standing still.

---

## Chapter 3: Tidying the workshop (June 15–17)

Before going further, I did some housekeeping. A "maintainability audit" listed eight messy spots in the code and cleaned up seven of them — deleting dead code, deleting a fake stub function, and splitting one giant 1,166-line file into four tidy ones. I also upgraded the map-fingerprinting to the stronger SHA-256 mentioned earlier.

Around the same time, the way the whole toolchain was installed got simplified, and I deleted a stack of complicated build files ("no flakes").

None of this was glamorous, but it's the difference between a project that stays buildable and one that collapses under its own mess.

---

## Chapter 4: Teaching the phone to run the AI — without melting (June 18–19)

Remember the old design ran the AI by *reloading the entire 2.4 GB model every single time* — that's where the brutal 50-seconds-per-frame came from. The fix was to load the AI **once** at the start of a session and keep it warm in memory, ready to answer instantly. Doing that required building a special version of the AI's engine (called **LiteRT-LM**) that Carty's C++ code could link to directly, instead of clumsily launching it as a separate program each time.

**June 18:** I successfully built and saved ("vendored") that engine. There was a hilarious-in-hindsight detour where the build refused to work on my Linux setup until I realized it was looking for a file at `/bin/bash` that simply didn't exist on my system, and I had to create a link to it.

**June 19 — the "empty answer" mystery, then the breakthrough.** With the engine wired up, the AI kept replying with… nothing. Empty. I eventually figured out the cause by reading the engine's own source code: the model expects its prompts to be wrapped in special marker text (little tags that say "here's where the user's turn starts" and "here's where your answer should go"). Without those markers, the model just immediately decided it was done and said nothing. Once I added the markers by hand, it answered perfectly.

That same day, the payoff landed. I ran the **whole thing on the real OnePlus phone** — Dart calling C++ calling the AI engine calling Gemma — and it worked. The measured numbers tell the story of why "load once, keep warm" mattered so much:

- **Loading the model: ~6 seconds** (paid once per session, not per frame).
- **Generating an answer: ~30 seconds** for a valid result (this particular model "thinks" a lot, which is slow but I expected it).
- **Memory used: about 2.44 GB** held in RAM the whole time.
- **Heat: mild.** The phone warmed up only a few degrees and never throttled, even running from 26% battery with no charger.

Compared to the old "50 seconds *every frame*," paying ~6 seconds *once* is a complete game-changer. This milestone — called "Gate A2" — was the project's single biggest unknown, and closing it meant the risky AI-on-a-phone question was finally answered: **yes, it works.**

---

## Chapter 5: Building the actual map (June 20)

Now the fun part — turning camera frames into a real top-down map. Two pieces of geometry do the heavy lifting.

**First, straightening the view.** When you hold a phone and film the floor, you're looking at it from an angle — the floor appears as a stretched trapezoid, not a neat square. A function in the C++ bridge (`carty_ortho_project`) performs **orthorectification**: it takes that tilted, angled image and mathematically warps it into a perfect straight-down view, as if a camera on the ceiling took it. After this step, each spot in the picture corresponds to a real, fixed location on the ground. (It's the same idea as un-skewing a photo of a document you took at an angle.)

**Second, stacking the snapshots into one map.** This is the part built on **June 20**, called the "fusion" stage. Picture a big invisible grid laid over the floor — Carty's docs call it a **voxel-column grid** (think of the floor divided into thousands of little squares, each square also tracking a bit of height information). A new function, `carty_world_grid_accrete`, takes one straightened snapshot *plus the pose* (remember — where the phone was and which way it pointed when that snapshot was taken) and stamps that snapshot onto the correct spot of the shared grid.

Here's the elegant trick: because every snapshot is placed using its real-world pose, snapshot #1 and snapshot #500 land in their correct, consistent positions on the *same* grid. Walk around a room and the snapshots overlap and build up — like laying down sheet after sheet of tracing paper until the full floor plan emerges.

Each grid square keeps a running tally (the docs call it **log-odds**) of how often it was seen — basically a confidence vote. See a spot many times → high confidence something's really there. This makes the map robust: one bad frame can't ruin it.

This fusion code was written **test-first** — meaning I wrote the tests *before* the code, watched them fail, then wrote code until they passed. I also ran it under special "sanitizer" tools that catch memory mistakes, and it came back perfectly clean. By the end of the day, both the C++ core and its Dart wrapper were finished and tested.

---

## Chapter 6: Making it real, live, and honest (June 21)

This was an enormous single day. The big theme: take everything that worked in the lab and turn it into something you can actually demo live, on a phone, in front of a client — what I call **the park test** (could you hand someone a phone in a park they picked and have it work?).

I organized the goal into a "**capability ladder**," where each rung is a more impressive thing you can show:

- **Rung 0:** "The phone tracks its position live and records a replayable capture."
- **Rung 1 (the hero moment):** "Watch a correct top-down map of *this place* fill in live as you walk."
- Rungs 2–4: walls/rooms/doors get recognized → the AI cleans up the confusing bits → it's rendered as a shareable D&D map.

Across that one day, I built and tested, piece by piece (writing tests first each time):

- A **pose sidecar** — a simple text file that records the phone's pose for every keyframe alongside the video. (A "sidecar" is just a companion file that travels with the main one.) This is gold, because it lets me *replay* a real walk on a plain computer afterward and get the exact same map every time — turning a messy real-world recording into something I can test precisely.
- A **heatmap painter** that draws the grid on screen, so you can literally watch the floor fill in.
- The **honesty overlay** — a small banner that tells the truth about quality, showing "HIGH," "LOW," or "DEGRADED." This matters because of Carty's core honesty rule: it must never *pretend* a rough map is accurate.
- **Rung 0, proven on the real phone.** A real walk recorded **644 keyframes** (621 with good tracking), saved a valid video plus its pose sidecar, and replayed perfectly afterward — 620 genuinely distinct positions, proving the phone really captured real movement through space.
- **The "hero moment" math, proven on the computer.** A more advanced version of the stamping function (`carty_world_grid_accrete_from_frame`) that uses the *full*, precise camera pose and lens details — the version needed so the live map doesn't smear as you walk — was built and shown to work correctly in replay.

Two other decisions were locked in that day. First, a second, lower-quality input mode was officially allowed: if someone gives Carty an ordinary video with *no* pose data, an on-device technique called **SLAM** (which estimates the camera's motion purely from the pixels) can try to recover the movement. It's less accurate, it's strictly a fallback, and — crucially — it still runs entirely on the phone, never the cloud. Second, I reordered the whole to-do list to be "demo-first," so every milestone produces something you can actually *show*, not just something hidden in a test log.

---

## Chapter 7: Wiring the live map — and the "blue smear" (June 22)

The day after the big push, I did the one thing I'd deliberately saved for a real phone in hand: I **wired the live loop**. Now, as you walk, each camera frame is stamped onto the shared grid *right then*, and the map repaints on screen — no more recording first and replaying later. This is the connection that turns all the proven-in-the-lab pieces into the live "hero moment."

The first walk, though, produced a now-famous bug I nicknamed the **"blue smear":** instead of a map, everything collapsed into a blob near one point. The cause is a lovely lesson in trusting your assumptions too much. I assumed the phone measures height from the *floor*. It doesn't — ARCore sets its "zero height" wherever the camera happened to be **when you pressed start**, usually chest-high. So the math that projects each pixel down onto the floor was aiming at the wrong level, and all the rays piled up at the origin. The fix: have the phone watch for the actual floor plane and report every height *relative to the floor it found*. After that, the map was geometrically sound — my reaction was "I can see the logic in it."

Sound, but still ugly. A grid of confidence votes is legible to a programmer, not to a person. So the current task is to make it **look like a map**: color each patch of floor with the real color the camera saw (a free byproduct the math was already throwing away), zoom to fit what you've actually scanned, and add a "you are here" arrow. That work is in progress right now — the first piece (a buffer to hold each cell's color) is being built test-first in the C++ core.

---

## Where Carty stands today (as of June 22, 2026)

Think of it as a two-act project, and Act One is essentially done.

**The riskiest questions have all been answered "yes":**
- Can a 2.4 GB AI model actually run on a phone, in reasonable time and heat? **Yes** (proven on the OnePlus, June 19).
- Can camera frames plus pose be fused into a consistent top-down grid? **Yes** (the fusion engine, June 20).
- Can the phone track itself and record a replayable capture live? **Yes** — that's Rung 0, proven on the device June 21.
- Can the map fill in *live* on the phone as you walk? **The wiring works and runs on the device** (June 22) — the geometry is sound after the floor-height fix; what's left is making it legible, not making it run.

**What's working right now:** the foundations (the language bridge, the Git-for-maps, the video tools), the on-device AI engine, the geometry that straightens and stacks frames into a map, a live on-device capture you can replay, and a **live walk-and-watch loop** that stamps frames onto the grid in real time. The whole system is held together by **100 automated tests passing** on the computer, plus a clean bill of health from the code analyzers.

**The "hero moment," in progress:** the live loop runs and tracks the floor correctly, but the on-screen map is still a raw confidence grid rather than something a person would recognize. The active work is the **colored, oriented, auto-fitting minimap** described above. True to the honesty rule, Carty still won't publicly claim "accurate live map" until that view is confirmed legible on a real walk — and I'm careful to say what the colored layer *is* (a top-down photo of the floor it has seen) and is *not* (the finished D&D map with walls and rooms, which comes later).

**Still ahead (Act Two):** recognizing actual walls, rooms, and doors from the grid; letting the AI clean up the ambiguous spots; stitching together huge spaces (the dream target is mapping the entire ~30 km Toronto PATH underground network, one overlapping segment at a time); and finally rendering it all as a polished, shareable D&D-style map.

---

## The one idea to take away

If you remember nothing else: Carty works because I figured out **which jobs go to predictable math and which go to the AI.** Math is great at precise, repeatable geometry — straightening images, stacking them by position, counting confidence. AI is great at fuzzy human judgment — but terrible (and slow, and prone to making things up) when you ask it to do precise geometry. The entire turning point of this project, on June 12, was discovering that the hard way and rebuilding around it.

Everything after that — the on-device engine, the fusion grid, the live capture — is just the careful, tested, day-by-day execution of that one good decision.
