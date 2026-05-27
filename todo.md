# Strata — Known Issues & Grievances

## Critical: App Doesn't Feel Native macOS

Strata is built with `WindowGroup` instead of `DocumentGroup`, which means it's missing
fundamental macOS document behaviors that users expect from any native app:

- [ ] **No filename popover in title bar** — clicking the filename in the title bar should
      show the standard macOS proxy icon / rename popover (path, rename, move, lock).
      Every document-based Mac app has this. Requires migrating to `DocumentGroup` or
      manually implementing `representedURL` / `NSSavePanel` proxy icon behavior.
- [ ] **No proxy icon** — the small document icon in the title bar that you can drag to
      Finder, attach to emails, etc. is completely absent.
- [ ] **No native Save/Revert integration** — standard apps get "Edited" dot in the close
      button, "Revert to Saved" in File menu, autosave conflict resolution. Strata has
      manual save but none of the system-level document lifecycle.
- [ ] **No state restoration** — reopening the app should restore all open documents and
      window positions. `DocumentGroup` provides this automatically.
- [ ] **Consider migrating from `WindowGroup` to `DocumentGroup`** — this would fix most
      of the above issues but is a significant architectural change. The current manual
      file management (OutlineStore.loadFile/saveFile) would need to be replaced with
      a proper `ReferenceFileDocument` or `FileDocument` conformance.

## Recurring: Formatting / Rendering Issues

- [x] **Formatting race condition** — styled text (bold, italic, code) flashes unstyled
      momentarily during editing. Root cause was `tf.font` being set in `applyStyle`,
      which strips all font attributes from `attributedStringValue`. Fix applied
      (moved to `makeNSView` only) and followed up by routing menu formatting commands
      through the active field editor plus restyling compatible markdown ranges.
- [x] **Attributed string fragility** — the entire inline formatting system (markdown-style
      `**bold**`, `*italic*`, `` `code` ``, `==highlight==`) is re-parsed and re-rendered
      on every keystroke. Any code path that touches `tf.font` or `tf.textColor` after
      initial setup can blow away the styled rendering. Follow-up pass keeps code spans
      isolated while allowing compatible bold/italic/highlight styling to combine.

## Recurring: Tab Bar Issues

- [x] **"+" button in tab bar** — the automatic new-tab button appears in the tab bar even
      though the app doesn't support creating new tabs from it. Fixed with
      `NSWindow.allowsAutomaticWindowTabbing = false` but this is a heavy-handed approach
      that also disables system tab merging features. Follow-up pass replaced the default
      New Window command with New Tab and explicitly attaches opened documents to the
      current tab group.
- [ ] **Tab bar graphical artifacts** — visual glitches in the tab bar area have been
      reported but root cause is unclear. May be related to the `tabbingMode` configuration
      or the interaction between SwiftUI `WindowGroup` and AppKit window tabbing.

## UX Issues

- [ ] **Empty nodes create confusing gaps** — blank outline items between paragraphs show
      as invisible gaps. Placeholder text was changed from `tertiaryLabelColor` to
      `secondaryLabelColor` for visibility, but the underlying issue remains: it's too easy
      to accidentally create empty nodes, and they're hard to notice/clean up.
- [x] **Multi-line selection discoverability** — Escape now enters selection mode (select
      current node), and Shift+Up/Down extends selection, but this isn't obvious to users.
      Mouse selection now follows Mac conventions: click the bullet to select, Shift-click
      to select a range, Command-click to toggle, and drag selected nodes as a block.
- [ ] **No keyboard shortcut reference** — the app has many keyboard shortcuts (Tab/Shift-Tab
      for indent, Cmd+Up/Down for move, Cmd+]/[ for zoom, etc.) but no way for users to
      discover them beyond the menu bar.

## Minor / Polish

- [ ] **Launch flow** — when no recent files exist, an empty window briefly appears before
      the open dialog. Current fix hides window with `orderOut` before showing panel, but
      the flash may still be visible on slow machines.
- [ ] **Undo granularity** — two-tier undo (field editor for text, store snapshots for
      structure) works but can feel inconsistent. Undoing a structural change after text
      edits may not behave as users expect.
- [ ] **OPML compatibility** — export formats (txt, md, html) exist but import only supports
      OPML. No way to import plain text or Markdown outlines.
