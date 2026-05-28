# Strata Agent Context

Strata is a native macOS outliner, closer in spirit to Workflowy than to a generic note app. Preserve native Mac conventions where they make sense, and treat outline editing as the core product surface.

## Product Goals

- Strata should feel like a real macOS document app: native windows, native tabs, proxy filename behavior where possible, standard save/open panels, recent documents, close prompts for unsaved untitled work, and predictable Cmd-key shortcuts.
- The outline should support fast writing and restructuring: text editing, node selection, drag and drop, cut/copy/paste, indent/outdent, moving nodes up/down, zoom/focus, completed-item hiding, search, and OPML persistence.
- Multi-node selection is a first-class feature, not a secondary mode. It must support keyboard selection, mouse range/toggle selection, deleting, copying, cutting, pasting, toggling completion, merging, and dragging selected nodes as a block.
- Inline formatting is rich text stored on nodes, not live Markdown rendering. Markdown-like markers (`**bold**`, `*italic*`, `==highlight==`) are input shortcuts that should be removed after applying formatting.
- OPML is the primary document format. Strata also exports text, Markdown, and HTML, and imports OPML plus outline-like text/Markdown paths where implemented.

## Key Behaviors

- `Cmd-T` opens a new tab in the current Strata tab group.
- `Cmd-W` closes the current tab/window and must route through the same unsaved-change prompt logic as the close button.
- `Cmd-Z` / `Cmd-Shift-Z` route to the active field editor while editing text and to `OutlineStore` snapshot undo/redo for structural outline changes.
- `Cmd-K` edits/removes a URL link for the selected text.
- `Cmd-L` applies highlight formatting to the selected text.
- Tab and Shift-Tab change hierarchy. Shift-Tab must relocate the node to the correct visible position for its new level, matching Workflowy-style outdent behavior rather than merely decrementing an indent number in place.
- Clicking a node bullet focuses/zooms that node. Clicking/shift-clicking/command-clicking selection affordances should preserve standard Mac selection expectations.
- The user expects the built `Strata.app` to be copied into the repo root after builds so `/Users/Yury/dev/strata/Strata.app` is the current executable.

## Architecture

- The app currently uses SwiftUI `WindowGroup`, with AppKit bridging for document-window behavior. This is a compromise, not an ideal endpoint.
- `StrataApp.swift` owns app commands, session restoration, recent files, tab coordination, launch/open-panel behavior, and AppKit window configuration.
- `OutlineStore` is the source of truth for outline data, selection state, drag state, undo snapshots, load/save, and structural editing.
- `OutlineNode` stores node text, children, completion/collapse state, notes, links/formatting spans, and copy helpers.
- `OPMLService` parses and serializes OPML and converts legacy Markdown-style formatting markers into formatting spans.
- `ExportService` handles text/Markdown/HTML export.
- `ContentView` wires the store to the main window, search bar, scroll view, selection bar, breadcrumbs, and window delegate.
- `NodeRowView` and `FlatOutline` render the outline rows, hierarchy guide lines, controls, selection background, drag/drop targets, and row-level gestures.
- `OutlineTextField` bridges to `NSTextField`/field editor for native text editing and rich-text formatting.

## Native macOS Decisions

- Prefer native AppKit/SwiftUI controls and document conventions over custom chrome. When native behavior is missing because of `WindowGroup`, bridge carefully with AppKit instead of inventing unrelated UI.
- `NSWindow.allowsAutomaticWindowTabbing` is disabled so tab creation stays under Strata's explicit Cmd-T/menu flow. New documents are manually attached to the current tab group.
- The titlebar/tabbar area has required several Tahoe/macOS 26 workarounds for scroll-edge effects and separators. Be careful with `WindowTabCoordinator`, `WindowConfigurator`, and `ScrollEdgeSuppressor`; repeated hierarchy scans can hurt scrolling smoothness.
- Strata intentionally keeps document content below the titlebar. Avoid full-size-content/titlebar-underlap changes unless the whole window model is being revisited.
- Migrating to `DocumentGroup` / `NSDocument` / `ReferenceFileDocument` may eventually be the right architectural fix for proxy icons, document popovers, native duplicate/save/revert behavior, and restoration. That migration is high-impact and should not be mixed with small bug fixes.

## Editing Model

- Text editing and node selection are distinct states that should transition smoothly.
- While editing text, native selection inside the field editor must remain possible.
- Escape enters node-selection mode for the current node; Enter exits node-selection mode and focuses the first selected node for editing.
- Multi-node selection uses `selectedNodeIds`, `selectionAnchorId`, and `selectionCursorId` in `OutlineStore`.
- Structural operations should call snapshot undo helpers before mutating tree structure.
- Text edits rely on the field editor undo manager. Do not indiscriminately register structural undo snapshots for ordinary typing.
- Drag/drop should move top-level selected nodes in visible order and skip children of selected parents to avoid duplicate moves.

## Formatting Model

- Do not set `NSTextField.font` or `textColor` during normal updates; doing so can strip attributed formatting from `attributedStringValue`.
- Rich formatting spans are persisted as model data and re-applied to attributed strings.
- Supported inline formatting includes bold, italic, highlight, manual links, and combinations where the model supports them.
- The old live Markdown display behavior was intentionally removed because hiding/showing markers caused visual jumps around the cursor.

## Layout and Rendering Notes

- The current outline uses a normal `VStack`, not `LazyVStack`. Virtualizing rows may improve large documents, but it can break drag/drop across large outlines and must be tested carefully before reintroducing.
- Row alignment is centralized in `OutlineLayoutMetrics`; adjust checkbox, chevron, bullet, text, and hierarchy guide positions there instead of scattering constants.
- Hierarchy guide lines should begin below the parent row controls and visually match Workflowy-style guides.
- Keep empty-document placeholder affordances subtle; the ellipsis is intentionally low contrast.
- Avoid expensive work in draw/layout paths. Chrome suppression and scroll-edge work should cache targets and throttle hierarchy scans.

## Build and Verification

- Build release:

```sh
xcodebuild -project Strata.xcodeproj -scheme Strata -configuration Release -derivedDataPath build/DerivedData build 2>&1 | rg -n "error:|warning:|BUILD"
```

- Copy and relaunch the built app:

```sh
rm -rf Strata.app
ditto build/DerivedData/Build/Products/Release/Strata.app Strata.app
osascript -e 'tell application "Strata" to quit' >/dev/null 2>&1 || true
sleep 1
open /Users/Yury/dev/strata/Strata.app
```

- Expected warnings may include an out-of-date CoreSimulator and skipped AppIntents metadata extraction. Treat Swift compile errors, signing errors, or new warnings as real issues.
- For visual work, manually check light and dark mode where relevant; several prior issues only appeared in one appearance.
- For tab/window work, test one tab, two tabs, closing back to one tab, relaunch with saved tabs, and opening a file into an existing tab group.

## High-Risk Areas

- Window/tab chrome: small AppKit changes can reintroduce ghost windows, tabbar flicker, scroll-edge bars, or separators.
- Rich text formatting: touching font/color assignment paths can make formatting disappear while editing.
- Undo routing: text undo and structural undo intentionally use different systems.
- Drag/drop: selection state, dragged IDs, drop target calculation, and visible order are tightly coupled.
- Outdent/reorder behavior: Shift-Tab must preserve a coherent tree, not just mutate depth.
- Session restoration: avoid creating ghost untitled documents when restoring previous documents or handling files opened by Finder.

## Repo Notes

- Keep unrelated refactors out of bug-fix commits.
- Prefer small, revertible commits for native-window work.
- Use `rg` for code search.
- Use `apply_patch` for manual edits.
- Do not remove `todo.md`; it captures known product and native-behavior gaps.
