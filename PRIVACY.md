# Privacy

MarDock collects nothing.

- **No network.** The app has no network entitlement, so macOS blocks it from
  connecting anywhere. There are no analytics, crash reporters, update checks,
  accounts or ads.
- **What it stores.** Your settings and the list of apps in your dock, in
  MarDock's own sandbox container on your Mac
  (`~/Library/Containers/io.github.aliraza47.MarDock`). Before hiding the macOS
  Dock it also stores the two Dock settings it changes, so it can put them back.
- **What it reads.** Which apps are running (to show them in the dock), app
  icons and names, the list of apps in your macOS Dock (once, if you ask it to
  import them) and the size and position of the frontmost app's windows (only
  in "hide when a window overlaps" mode — never window contents or titles).
- **Permissions.** None of the privacy-protected permissions (Accessibility,
  Screen Recording, Input Monitoring, Automation, Full Disk Access, Contacts,
  Calendars, Photos, Location, Camera, Microphone) are used or requested.

To remove everything MarDock stored, quit it and delete the container folder
above.
