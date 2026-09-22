# Countdown Menu Bar

A small macOS menu bar app for counting down to exact event dates and times.

## Build and launch

Requires Xcode to build the app and its native widget extension. The menu bar app runs on macOS 13 or later; desktop widgets require macOS 14 or later. From this folder:

```sh
sh scripts/build-app.sh
open "dist/Countdown Menu Bar.app"
```

The app appears only in the menu bar. Click **⏳ Add event** to create your first event. Set its name, date, time down to the second, and time zone. Click an event in the dropdown to choose which countdown appears in the menu bar. The dropdown shows every saved event, its exact deadline and zone, and a detailed countdown. Use the dropdown to edit or delete the selected event.

## Progressive precision

The menu bar shows more detail as the deadline approaches:

| Time remaining | Example |
| --- | --- |
| 7 days or more | CVPR2026 · 49d |
| 1–7 days | CVPR2026 · 3d 8h |
| 1–24 hours | CVPR2026 · 8h 24m |
| Under 1 hour | CVPR2026 · 24m 16s |

These compact units use elapsed time (one day is 24 hours), rounding down except seconds, which round up. The dropdown retains calendar years, months, days, hours, minutes, and seconds.

A custom moon fills from empty at 30 days to a quarter at 7 days, half at 24 hours, three-quarters at 1 hour, and full at the deadline. Its color moves from green through yellow and orange to red. Phase and color transitions animate briefly, without repeating motion; macOS Reduce Motion disables the transitions. A checkmark appears when the deadline is reached.

## Time zones

Each event stores its own time zone. Type a city or region into the zone field to filter the list, then select a result. **Local** uses your Mac's current named zone when selected; **UTC** and **AoE (UTC−12)** are shortcuts. AoE has a fixed offset throughout the year.

Changing a zone keeps the entered date and clock time and reinterprets the deadline. For example, 23:59:59 AoE is 11:59:59 UTC the following day. AoE does not automatically set the time to the end of the day. The editor previews the UTC equivalent and applicable offset.

Named zones follow daylight saving rules. Nonexistent clock times are rejected; when a time occurs twice, the first occurrence is used and the editor explains the chosen offset. Existing events retain their exact deadlines and receive the current local zone when first loaded by this version.

Events and the selected event are saved locally in macOS UserDefaults. A finished event displays **Done** and stays in the list until you delete it.

## Native desktop widget

1. Quit the previous version and open the newly built app once. You can copy it to Applications for a permanent installation.
2. Right-click the desktop and choose **Edit Widgets**.
3. Find **Countdown Menu Bar** / **Countdown Events** and choose a small, medium, or large widget.

Small widgets show one event per page, medium widgets show two, and large widgets show six. Use the arrow buttons to browse all events. Upcoming deadlines appear first; completed events follow, most recent first. Widgets of the same size share their current page. Clicking an event selects it in the menu bar app.

Events come directly from the app's saved list, including their individual time zones. Adding, editing, or deleting an event requests a widget update. The widget supplies minute-by-minute entries and deadline boundaries; macOS controls when those updates appear. During the final hour it uses a system-rendered `minutes:seconds` timer that stops at zero. The menu bar keeps its existing second-by-second updates.

The Xcode project is `Countdown.xcodeproj`, with the shared **Countdown** scheme. The build script signs both targets for local use and embeds the widget inside the app. The widget has read-only sandbox access to the app's preference domain; it cannot edit event data. Page selection is stored separately in the widget's own preferences. For an App Store release, replace the temporary shared-preference entitlement with a provisioned App Group.

Run `sh scripts/check.sh` to check the countdown date calculations.

## App icon

The crescent countdown logo is stored in `Assets/AppIcon.png`, with a macOS icon bundle at `Assets/CountdownIcon.icns`. The Xcode app target includes this icon. To regenerate the icon sizes from the source PNG, run `sh scripts/build-icon.sh`. The generation prompt is recorded in `Assets/LogoPrompt.md`.
