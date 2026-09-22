# Countdown Menu Bar

A small macOS menu bar app for counting down to exact event dates and times.

## Build and launch

Requires macOS 13 or later and the Swift command line tools. From this folder:

```sh
sh scripts/build-app.sh
open "dist/Countdown Menu Bar.app"
```

The app appears only in the menu bar. Click **⏳ Add event** to create your first event. Set its name, date, and time down to the second. Click an event in the dropdown to choose which countdown appears in the menu bar. The dropdown shows every saved event and its current countdown. Use the dropdown to edit or delete the selected event.

Events and the selected event are saved locally in macOS UserDefaults. A finished event displays **Done** and stays in the list until you delete it.

Run `sh scripts/check.sh` to check the countdown date calculations.
