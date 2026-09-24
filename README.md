# Countdown Menu Bar

A small macOS menu bar app for counting down to exact event dates and times.

[Download the latest release](https://github.com/Kymer0615/mac_countdown/releases/latest) · [Support the project](#support)

<a href="https://buymeacoffee.com/ziyang"><img src="docs/images/buy-me-a-coffee.svg" alt="Buy me a coffee" height="36"></a>

![Animated countdown: a full green moon wanes from the start to the critical window, then fills toward red before becoming a checkmark.](docs/images/moon-progress.gif)

**A glance is all it takes.** The moon wanes from each event's start to your critical window, then fills toward the deadline. The countdown moves from days to hours, minutes, and seconds.

*Accelerated illustration using the app’s moon-drawing code. The app updates once per second; it does not continuously loop through phases. [View the still image](docs/images/moon-progress.png).*

## Install with Homebrew

```sh
brew install --cask kymer0615/tap/countdown-menu-bar
open "/Applications/Countdown Menu Bar.app"
```

Requires macOS 13 or later, on Apple Silicon or Intel. Desktop widgets require macOS 14 or later.
The initial release is ad hoc signed and is not notarized by Apple. If macOS blocks the first launch, follow [Apple's instructions](https://support.apple.com/en-gb/102445) to allow it in **System Settings → Privacy & Security → Open Anyway**, then open it again.

If you already installed a copy manually, quit it and move that app bundle out of Applications before installing through Homebrew. Your saved events are stored separately and are retained.

```sh
brew update
brew upgrade --cask kymer0615/tap/countdown-menu-bar
# Remove the app (saved events are retained):
brew uninstall --cask countdown-menu-bar
```

## See it in action

### One countdown in your menu bar. Every event a click away.

<img src="docs/images/menu-bar.png" alt="Menu bar showing Project launch with a partially filled moon and 3 days 8 hours remaining" width="242">

<img src="docs/images/event-menu.png" alt="Open event dropdown listing seven sample events, exact deadlines, time zones, and countdowns, with Project launch selected" width="720">

Choose an event to pin its countdown to the menu bar. Add, edit, and delete events from the same dropdown.

### Your events, on your desktop

<table>
  <tr>
    <td align="center" valign="top">
      <strong>Small · one event</strong><br><br>
      <img src="docs/images/widget-small.png" alt="Small widget showing Project launch and page 1 of 7" width="170"><br><br>
      <strong>Medium · two events</strong><br><br>
      <img src="docs/images/widget-medium.png" alt="Medium widget showing Project launch in UTC and Design review in AoE" width="360">
    </td>
    <td align="center" valign="top">
      <strong>Large · six events</strong><br><br>
      <img src="docs/images/widget-large.png" alt="Large widget showing six sample deadlines and page controls to browse the remaining events" width="360">
    </td>
  </tr>
</table>

*Menu screenshots and native widget view previews use sample events. Widget backgrounds can vary with your desktop settings. Every size has page arrows to browse the full event list.*

## Build and launch

Requires Xcode to build the app and its native widget extension. The menu bar app runs on macOS 13 or later; desktop widgets require macOS 14 or later. From this folder:

```sh
sh scripts/build-app.sh
open "dist/Countdown Menu Bar.app"
```

The app appears only in the menu bar. Click **⏳ Add event** to create your first event. Set its name, deadline down to the second, time zone, start, and critical window. Each date has a calendar button for picking a day; the typed clock time is kept. Click an event in the dropdown to choose which countdown appears in the menu bar. The dropdown shows every saved event, its exact deadline and zone, and a detailed countdown. Use the dropdown to edit or delete the selected event.

## Progressive precision

The menu bar shows more detail as the deadline approaches:

| Time remaining | Example |
| --- | --- |
| 7 days or more | Vacation · 49d |
| 1–7 days | Vacation · 3d 8h |
| 1–24 hours | Vacation · 8h 24m |
| Under 1 hour | Vacation · 24m 16s |

These compact units use elapsed time (one day is 24 hours), rounding down except seconds, which round up. The dropdown retains calendar years, months, days, hours, minutes, and seconds.

Each event has a **start** (now, by default) and a **critical window**. The moon stays **full and green before the start**, wanes to empty between the start and the critical window, then fills again toward the deadline. Color expresses urgency independently: green → yellow at the critical boundary → red at the deadline. A checkmark appears when the deadline is reached. Starts may be in the past or future; the menu bar always counts down to the deadline.

The critical window defaults to **24 hours**. Choose **Seconds**, **Minutes**, **Hours**, **Days**, **Months**, a **Custom duration** (months, days, hours, minutes, and seconds together), or an **Exact date and time**. The editor shows the resolved boundary in the event's zone and in UTC.

- Seconds, minutes, and hours are elapsed time and accept decimals (resolved to whole seconds). The minimum is one second; there is no upper limit apart from dates the calendar cannot represent.
- Days and months are calendar units in the event's zone. **1 day and 24 hours can differ** across a daylight-saving change. Months are whole calendar months; a month before 31 March is 28 (or 29) February.
- If the critical boundary falls before the start, the event begins already in its critical phase; the window is not shortened.

Editing an event keeps its creation time. Events from version 1.2 keep their deadlines and critical hours, and use their creation time as the start.

Phase changes animate briefly, without repeating motion; macOS Reduce Motion disables these transitions. The menu bar and widgets use the same lifecycle.

## Time zones

Each event stores its own time zone. Type a city or region into the zone field to filter the list, then select a result. **Local** uses your Mac's current named zone when selected; **UTC** and **AoE (UTC−12)** are shortcuts. AoE has a fixed offset throughout the year.

Changing a zone keeps the entered date and clock time and reinterprets the deadline. For example, 23:59:59 AoE is 11:59:59 UTC the following day. AoE does not automatically set the time to the end of the day. The editor previews the UTC equivalent and applicable offset.

Named zones follow daylight saving rules. Nonexistent clock times are rejected; when a time occurs twice, the first occurrence is used and the editor explains the chosen offset. Existing events retain their exact deadlines and receive the current local zone when first loaded by this version.

Events and the selected event are saved locally in macOS UserDefaults. Before upgrading saved events from version 1.2, the app keeps a backup copy of the previous data; unreadable data is reported instead of being replaced with an empty list. A finished event displays **Done** and stays in the list until you delete it.

## Events and settings window

<img src="docs/images/events-window.png" alt="Events window with sample countdowns, their starts and critical windows, pin buttons, edit controls, and Sync, Settings, and About tabs" width="760">

Choose **Events & Settings…** in the menu bar dropdown. The Events tab lets you add, edit, delete, and pin countdowns; it also shows each event's start, critical window, and any Calendar or Reminders links. The **Sync** tab imports items from Calendar and Reminders (see below), and **About** shows the version and project links. The Settings tab offers:

- **Start at login**, using macOS Login Items. If approval is needed, the app links to System Settings.
- **Font style:** System, Rounded, Serif, or Monospaced.
- **Font size:** 10–22 pt for the menu bar, events window, and event editor. Widgets retain their system-sized layout.
- **Calendar and Reminders access:** the current status of each service, with a button to request access or open System Settings.

<img src="docs/images/settings-window.png" alt="Settings showing Start at login, font style and size controls, moon phase behavior, and Calendar and Reminders access" width="760">

Keep the app in Applications before enabling login startup. Settings are saved locally.

## Calendar and Reminders

On first launch after installing or upgrading, the app briefly explains why it asks, then macOS requests **Calendar** and **Reminders** access one after the other. You can allow either, both, or neither; declining one does not skip the other, and local countdowns work without access. Change this later in **Settings**.

### Adding countdowns to Calendar or Reminders

In both **Add Event** and **Edit Event**, the **Also create** section shows a checkbox for each service you have allowed. Both are off by default. If neither service is allowed, the section links to the integration settings instead.

- **Add to Calendar** creates a 30-minute event starting at the deadline in your default calendar. Add-only (write-only) Calendar access is enough for this.
- **Add to Reminders** creates a reminder due at the exact deadline in your default list.
- Each item links back to its countdown. The countdown is saved first; if one service fails, the other still succeeds and retrying never creates a second copy.
- Once linked, the editor shows the link instead of another checkbox. Local edits are not sent until you tick **Update linked … when saving** (requires full access). Deleting a countdown never deletes the Calendar event or reminder.

### Syncing items into countdowns

Open **Sync** (also in the menu bar dropdown). Sync is **one-way**: Calendar and Reminders stay the source, and countdowns follow them. Nothing is imported until you choose.

- Pick calendars or lists, search by title, and (for Calendar) a date range. The default range is today through one year ahead.
- **Sync Selected** follows only the items you tick. **Sync All Matching** follows every eligible item in the chosen sources, range, and search, including new ones added later.
- Calendar countdowns end at the event's start. All-day events count to midnight at the start of their day; date-only reminders count to 23:59:59 on their due date. Reminders without a due date cannot be synced; use **Add Event** for those.
- Syncing runs on launch, when you click **Sync Now**, and shortly after Calendar or Reminders change while the app is running. It does not run while the app is quit.
- Name, deadline, and time zone follow the source. Start and critical window stay editable. Use **Open Source** to view the item, or **Detach to Edit Locally** to stop following it.
- Each recurring event occurrence becomes its own countdown. Completing a reminder marks its countdown done; reopening it restores the countdown.
- If a source item is deleted or becomes unavailable, the countdown keeps its last values and is marked. Removing a synced countdown stops it from being re-added; **Clear Removed** undoes that.
- **Stop Sync** keeps existing countdowns as local copies. It does not change permissions or your calendars and reminders.
- Items created by this app are recognized by their link and are not imported a second time.

## Siri and Shortcuts

Open the app once, then find **Create Countdown** under Countdown Menu Bar in Shortcuts. Supply an event name and deadline; optionally a start, Calendar and Reminders additions, and a critical window. The deadline is an absolute date/time; its display uses your local time zone.

The critical window can be set with **Critical window amount** and **unit**. When an amount is given, it overrides the older **Critical window in hours** setting, which remains for shortcuts saved with earlier versions. If a requested Calendar or Reminders addition is not allowed, the countdown is still created and the result says which addition failed.

Say **“Create a countdown in Countdown Menu Bar”** to Siri, or make a named shortcut with your preferred options and invoke that shortcut through Siri. The action integrates through Apple App Intents, including on Macs using Apple Intelligence Siri. Voice recognition and action availability depend on the macOS version, language, Siri configuration, and system indexing; this app does not provide its own AI assistant.

## Native desktop widget

1. Quit the previous version and open the newly built app once. You can copy it to Applications for a permanent installation.
2. Right-click the desktop and choose **Edit Widgets**.
3. Find **Countdown Menu Bar** / **Countdown Events** and choose a small, medium, or large widget.

Small widgets show one event per page, medium widgets show two, and large widgets show six. Use the arrow buttons to browse all events. Upcoming deadlines appear first; completed events follow, most recent first. Widgets of the same size share their current page. Clicking an event selects it in the menu bar app.

Events come directly from the app's saved list, including their individual time zones. Adding, editing, or deleting an event requests a widget update. The widget supplies minute-by-minute entries and deadline boundaries; macOS controls when those updates appear. During the final hour it uses a system-rendered `minutes:seconds` timer that stops at zero. The menu bar keeps its existing second-by-second updates.

The Xcode project is `Countdown.xcodeproj`, with the shared **Countdown** scheme. The build script signs both targets for local use and embeds the widget inside the app. The widget has read-only sandbox access to the app's preference domain; it cannot edit event data. Page selection is stored separately in the widget's own preferences. For an App Store release, replace the temporary shared-preference entitlement with a provisioned App Group.

Run `sh scripts/check.sh` for date, migration, critical-window, moon-lifecycle, and widget checks. Run `sh scripts/check-app.sh` in a macOS GUI session for permission, editor rendering, export, sync, font persistence, and App Intent checks. It uses isolated sample data and a simulated Calendar/Reminders store. It never prompts for access, reads your calendars, creates items, or changes login settings.

## Publishing a release

1. Set matching versions and increment build numbers in both `Build` Info.plist files. Commit the release changes on a clean branch.
2. Run `sh scripts/package-release.sh v1.3.0` (replace the version for future releases). This runs checks, builds both architectures, verifies signatures, and writes a ZIP and `.sha256` file to `dist/`. Existing archives are never overwritten.
3. Authenticate with `gh auth login`, then tag the committed source and push the tag:

   ```sh
   git tag -a v1.3.0 -m "Countdown Menu Bar 1.3.0"
   git push origin main v1.3.0
   gh release create v1.3.0 dist/Countdown-Menu-Bar-1.3.0-universal.zip dist/Countdown-Menu-Bar-1.3.0-universal.zip.sha256 --verify-tag --title "Countdown Menu Bar 1.3.0" --notes-file dist/release-notes.md
   ```

   Write release notes to `dist/release-notes.md` first, including the signing limitation. The repository and release downloads must be public.
4. In `Kymer0615/homebrew-tap`, update `Casks/countdown-menu-bar.rb` with the release version and archive SHA-256. Run `brew style --cask countdown-menu-bar` and `brew audit --cask countdown-menu-bar` with the tap installed, then commit and push.

Published release assets must remain unchanged; fixes get a new version and tag. The packaging script skips local LaunchServices registration so preparing a release does not select it as the installed app.

## Support

If Countdown Menu Bar is useful to you, you can support its development:

<a href="https://buymeacoffee.com/ziyang"><img src="docs/images/buy-me-a-coffee.svg" alt="Buy me a coffee" height="36"></a>

The **About** tab in the app has the same link and a link to this repository. Both open in your browser; nothing is charged automatically.
