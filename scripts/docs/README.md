# README visuals

Run from the repository root on macOS:

```sh
sh scripts/docs/render.sh
```

Requires Xcode command-line tools, an active graphical session, and Screen Recording permission for the terminal running the capture. The script briefly shows a sample menu and a plain backdrop, then closes both. Keep the menu undisturbed until the capture finishes.

- Compiles the app and widget view code with their normal entry points removed into `.build/docs`.
- Uses a standalone executable's preferences domain for sample events. It does not change the installed app's saved events.
- Captures only the demo status item, its dropdown, and the events/settings windows. Widget images render the actual SwiftUI content with a dark rounded background; they are previews rather than screenshots of desktop widget placement.
- Generates the accelerated creation-to-critical-window-to-deadline GIF with `MoonIcon`, `MoonProgress`, and `CountdownFormat`, and includes a still PNG alternative. The final frame uses the app's completion checkmark.
- Writes public assets to `docs/images`. Inspect all images before committing them.

No app rebuild or new release is needed when updating these documentation assets.
