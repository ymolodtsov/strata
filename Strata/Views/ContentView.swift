import SwiftUI

struct ContentView: View {
    @Bindable var store: OutlineStore
    @State private var eventMonitor: Any?
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Search bar
            if store.isSearchActive {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                        .font(.system(size: 13))
                    TextField("Search...", text: $store.searchQuery)
                        .textFieldStyle(.plain)
                        .font(.system(size: 14))
                        .focused($searchFocused)
                    if !store.searchQuery.isEmpty {
                        Button {
                            store.searchQuery = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.tertiary)
                                .font(.system(size: 12))
                        }
                        .buttonStyle(.plain)
                    }
                    Button {
                        store.isSearchActive = false
                        store.searchQuery = ""
                    } label: {
                        Text("Done")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 32)
                .padding(.vertical, 8)
                .background(Color(.textBackgroundColor))

                Divider().opacity(0.5)
            }

            if !store.zoomPath.isEmpty {
                HStack(spacing: 8) {
                    Button {
                        store.zoomOut()
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)

                    Text(store.currentRoot.text.isEmpty ? "Untitled" : store.currentRoot.text)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Spacer()
                }
                .padding(.horizontal, 32)
                .padding(.top, 20)
                .padding(.bottom, 2)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        FlatOutline(store: store)
                    }
                    .padding(.top, store.zoomPath.isEmpty ? 16 : 8)
                    .padding(.bottom, 60)
                    .padding(.horizontal, 28)
                }
                .onChange(of: store.pendingFocusId) { _, newId in
                    if let id = newId {
                        withAnimation(.easeInOut(duration: 0.15)) {
                            proxy.scrollTo(id, anchor: .center)
                        }
                    }
                }
            }

            if !store.zoomPath.isEmpty {
                Divider()
                    .opacity(0.5)
                BreadcrumbView(store: store)
            }
        }
        .navigationTitle(store.documentTitle)
        .background(Color(.textBackgroundColor))
        .background(WindowConfigurator(store: store, url: store.currentFilePath))
        .frame(minWidth: 400, minHeight: 300)
        .onAppear {
            removeEventMonitor()
            installEventMonitor()
        }
        .onDisappear { removeEventMonitor() }
        .onChange(of: store.isSearchActive) { _, active in
            if active {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    searchFocused = true
                }
            }
        }
    }

    private func installEventMonitor() {
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Only handle events for the key window (avoid cross-tab interference)
            guard event.window?.isKeyWindow == true else { return event }

            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

            // Note: Cmd+Z / Cmd+Shift+Z (Undo/Redo) are handled by the menu bar
            // commands which route to either the field editor's undo manager (during
            // text editing) or the store's snapshot undo (when not editing).

            // Cmd+F — Toggle search (always active)
            if event.keyCode == 3 && flags == .command {
                store.isSearchActive.toggle()
                if !store.isSearchActive { store.searchQuery = "" }
                return nil
            }
            // Cmd+Shift+Enter — Toggle note on focused node
            if event.keyCode == 36 && flags == [.command, .shift] {
                if let focusedId = store.pendingFocusId ?? store.visibleNodes().first?.node.id {
                    store.toggleNote(nodeId: focusedId)
                }
                return nil
            }

            guard store.hasSelection else { return event }

            // Escape — clear selection
            if event.keyCode == 53 {
                store.clearSelection()
                return nil
            }
            // Shift+Up — extend selection upward
            if event.keyCode == 126 && flags == .shift {
                store.extendSelectionUp()
                return nil
            }
            // Shift+Down — extend selection downward
            if event.keyCode == 125 && flags == .shift {
                store.extendSelectionDown()
                return nil
            }
            // Cmd+Up — move selected nodes up
            if event.keyCode == 126 && flags == .command {
                store.moveSelectedUp()
                return nil
            }
            // Cmd+Down — move selected nodes down
            if event.keyCode == 125 && flags == .command {
                store.moveSelectedDown()
                return nil
            }
            // Cmd+Shift+Up — existing move-up alias
            if event.keyCode == 126 && flags == [.command, .shift] {
                store.moveSelectedUp()
                return nil
            }
            // Cmd+Shift+Down — existing move-down alias
            if event.keyCode == 125 && flags == [.command, .shift] {
                store.moveSelectedDown()
                return nil
            }
            // Up — move single selection up
            if event.keyCode == 126 && flags.isEmpty {
                store.moveSelectionUp()
                return nil
            }
            // Down — move single selection down
            if event.keyCode == 125 && flags.isEmpty {
                store.moveSelectionDown()
                return nil
            }
            // Enter — exit selection, edit first selected node
            if event.keyCode == 36 && flags.isEmpty {
                store.focusFirstSelected()
                return nil
            }
            // Backspace — delete selected
            if event.keyCode == 51 && flags.isEmpty {
                store.deleteSelected()
                return nil
            }
            // Cmd+Enter — toggle done on selected
            if event.keyCode == 36 && flags == .command {
                store.toggleDoneSelected()
                return nil
            }
            // Cmd+C — copy selected as text
            if event.keyCode == 8 && flags == .command {
                store.copySelectedAsText()
                return nil
            }
            // Cmd+X — cut selected nodes
            if event.keyCode == 7 && flags == .command {
                store.cutSelected()
                return nil
            }
            // Cmd+V — paste nodes after selection
            if event.keyCode == 9 && flags == .command {
                store.pasteAfterSelection()
                return nil
            }
            // Tab in selection — indent selected nodes as a block
            if event.keyCode == 48 && flags.isEmpty {
                store.indentSelected()
                return nil
            }
            // Shift+Tab in selection — unindent selected nodes as a block
            if event.keyCode == 48 && flags == .shift {
                store.unindentSelected()
                return nil
            }
            // Any printable character — exit selection, start editing
            // (exclude control characters like Tab=0x09, Escape=0x1B, etc.)
            if let chars = event.characters, flags.isEmpty {
                let scalar = chars.unicodeScalars.first
                if let s = scalar, s.value >= 0x20 {
                    store.focusFirstSelected()
                    return event
                }
            }

            return event
        }
    }

    private func removeEventMonitor() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }
}

// MARK: - Window Configuration (proxy icon + native tabbing)

struct WindowConfigurator: NSViewRepresentable {
    let store: OutlineStore
    let url: URL?

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            WindowTabCoordinator.configure(view.window)
            if let window = view.window {
                SessionState.associate(store: store, with: window)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            nsView.window?.representedURL = url
            WindowTabCoordinator.configure(nsView.window)
            if let window = nsView.window {
                SessionState.associate(store: store, with: window)
            }
        }
    }
}
