# Privacy

MarDock collects nothing.

- **No network, except updates you ask for.** The dock has no network
  entitlement, so macOS blocks it from connecting anywhere. There are no
  analytics, crash reporters, accounts or ads.
- **Update checks.** Only when you choose Check for Updates, or once a day if
  you turn that on in Settings ▸ About (it's off). A separate, sandboxed part
  of MarDock asks GitHub for this repository's latest release and, when you
  install one, downloads it. The requests carry no identifiers, cookies or
  settings, but like any connection GitHub sees your IP address and that
  MarDock is asking; GitHub's privacy statement covers what it does with
  that.
- **What it stores.** Your settings, what you keep in your dock (apps,
  spacers, dividers, folders) and in each profile, themes you make, the last
  few apps you brought to the front (for the recent apps section: their names
  and locations only) and any icons you pick for apps, in MarDock's own
  sandbox container on your Mac
  (`~/Library/Containers/io.github.aliraza47.MarDock`). So are shortcuts you
  make for apps: their titles and the websites, files or Shortcuts they open.
  Before hiding the macOS Dock it also stores the Dock settings it changes, so
  it can put them back.
  For updates it keeps whether the daily check is on, when it last checked
  and the last version it told you about.
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
- **Extras you turn on.** Off unless you switch them on: a full Trash icon
  (reads only how many items the Trash holds), notification badges (the
  badge text on the macOS Dock's icons) and minimized windows (their titles),
  which need Accessibility, and window previews, which need Screen Recording:
  small pictures of the windows of the app you point at, shown and never
  kept or sent anywhere.
- **Apps' own commands.** With Accessibility allowed, double-clicking an app
  reads the New and Open commands in its File menu, to show them, and chooses
  the one you click. Nothing else in the menu is kept or even looked at past
  its title, and nothing is stored.
- **Permissions.** Accessibility and Screen Recording only for the extras
  above and apps' own commands, if you use them, and Automation for Finder the first time you
  choose Empty Trash (MarDock asks Finder to empty it and can send Finder no
  other command). Input Monitoring, Full Disk Access,
  Contacts, Calendars, Photos, Location, Camera and Microphone are never used
  or requested.

To remove everything MarDock stored, quit it and delete the container folder
above.
