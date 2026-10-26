# Privacy

MarDock collects nothing.

- **No network.** The app has no network entitlement, so macOS blocks it from
  connecting anywhere. There are no analytics, crash reporters, update checks,
  accounts or ads.
- **What it stores.** Your settings, what you keep in your dock (apps,
  spacers, dividers, folders) and in each profile, themes you make, the last
  few apps you brought to the front (for the recent apps section: their names
  and locations only) and any icons you pick for apps, in MarDock's own
  sandbox container on your Mac
  (`~/Library/Containers/io.github.aliraza47.MarDock`). Before hiding the macOS
  Dock it also stores the two Dock settings it changes, so it can put them back.
- **Keyboard shortcuts.** ⌃⌥1–9 are registered as system hot keys: macOS tells
  MarDock when one of those exact combinations is pressed and nothing else.
  MarDock never sees other keystrokes.
- **What it reads.** Which apps are running and which one is in front (to
  show them in the dock and keep the recent apps list), app
  icons and names, the list of apps in your macOS Dock (once, if you ask it to
  import them) and the size and position of the frontmost app's windows (only
  in "hide when a window overlaps" mode — never window contents or titles),
  files you pick yourself in an Open or Save panel (apps to add, images for
  icons, themes and settings files) and the folders you add to the dock (to
  show their newest files) — nothing else on your Mac.
- **Permissions.** None of the privacy-protected permissions (Accessibility,
  Screen Recording, Input Monitoring, Automation, Full Disk Access, Contacts,
  Calendars, Photos, Location, Camera, Microphone) are used or requested.

To remove everything MarDock stored, quit it and delete the container folder
above.
