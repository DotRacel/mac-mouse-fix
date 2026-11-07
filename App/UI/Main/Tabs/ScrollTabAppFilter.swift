//
// --------------------------------------------------------------------------
// ScrollTabAppFilter.swift
// Created for Mac Mouse Fix (https://github.com/noah-nuebling/mac-mouse-fix)
// Licensed under the MMF License (https://github.com/noah-nuebling/mac-mouse-fix/blob/master/License)
// --------------------------------------------------------------------------
//

/// UI for `Scroll.appExceptions` – apps where Mac Mouse Fix turns off smooth scrolling. [Nov 2026]
///     The Helper side lives in `ScrollAppFilter.swift`. See that file for the config format and behavior.
///     Built in code instead of in `Main.storyboard` to keep the diff small and mergeable with upstream.

import Cocoa
import UniformTypeIdentifiers

// MARK: - Config model

fileprivate struct AppFilterEntry: Equatable {
    var bundleID: String?
    var path: String?

    init?(dict: NSDictionary) {
        bundleID = dict["bundleID"] as? String
        path = dict["path"] as? String
        if (bundleID ?? "").isEmpty && (path ?? "").isEmpty { return nil }
    }
    init(bundleID: String?, path: String?) {
        self.bundleID = bundleID
        self.path = path
    }

    var dict: NSDictionary {
        if let bundleID { return ["bundleID": bundleID] }
        return ["path": path ?? ""]
    }

    /// Display

    private var appURL: URL? {
        if let bundleID { return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) }
        if let path { return URL(fileURLWithPath: path) }
        return nil
    }
    var displayName: String {
        if let url = appURL, FileManager.default.fileExists(atPath: url.path) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        return bundleID ?? (path as NSString?)?.lastPathComponent ?? "?"
    }
    var icon: NSImage {
        if let url = appURL, FileManager.default.fileExists(atPath: url.path) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }
        if #available(macOS 11.0, *) { return NSWorkspace.shared.icon(for: .application) }
        return NSWorkspace.shared.icon(forFileType: "app")
    }
}

fileprivate enum AppExceptionsConfig {

    static func load() -> [AppFilterEntry] {
        let apps = config("Scroll.appExceptions") as? [NSDictionary] ?? [] /// Optional – older configs don't have this key
        return apps.compactMap { AppFilterEntry(dict: $0) }
    }

    static func commit(_ entries: [AppFilterEntry]) {
        setConfig("Scroll.appExceptions", NSMutableArray(array: entries.map { $0.dict }))
        commitConfig()
    }
}

// MARK: - Scroll tab section

@available(macOS 11.0, *)
extension ScrollTabController {

    /// Appends a divider and the "App Exceptions:" row to `masterStack`.
    func installAppFilterSection() {

        /// Divider (Same layout as the dividers in Main.storyboard)
        let divider = NSView()
        divider.translatesAutoresizingMaskIntoConstraints = false
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        line.setContentHuggingPriority(.init(1000), for: .vertical)
        divider.addSubview(line)
        NSLayoutConstraint.activate([
            line.leadingAnchor.constraint(equalTo: divider.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: divider.trailingAnchor),
            line.topAnchor.constraint(equalTo: divider.topAnchor, constant: 8),
            line.bottomAnchor.constraint(equalTo: divider.bottomAnchor, constant: -8),
        ])

        /// Row
        let label = NSTextField(labelWithString: MFLocalizedString("scroll-app-filter.label", comment: "Label in the Scrolling tab. Followed by a button that opens the list of apps where Mac Mouse Fix turns off smooth scrolling."))
        let editButton = NSButton(title: MFLocalizedString("scroll-app-filter.edit-button", comment: "Button next to 'App Exceptions:' in the Scrolling tab. Opens a sheet for editing the list of apps."), target: nil, action: nil)
        editButton.bezelStyle = .rounded
        editButton.setAccessibilityIdentifier("axScrollingAppFilterEditButton")
        editButton.target = self
        editButton.action = #selector(openAppFilterSheet)
        let row = NSStackView(views: [label, editButton])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 8
        /// Hug the content tightly – `TabViewController.resizeWindowToFit()` measures the tab inside a huge window, and with NSStackView's default (low) hugging this row would absorb all the extra height.
        row.setHuggingPriority(.init(1000), for: .vertical)
        row.translatesAutoresizingMaskIntoConstraints = false

        masterStack.addArrangedSubview(divider)
        masterStack.addArrangedSubview(row)
        divider.widthAnchor.constraint(equalTo: masterStack.widthAnchor).isActive = true
    }

    @objc func openAppFilterSheet() {
        guard let presenter = MainAppState.shared.tabViewController else { assert(false); return }
        presenter.presentAsSheet(ScrollAppFilterSheetController())
    }
}

// MARK: - Sheet

@available(macOS 11.0, *)
class ScrollAppFilterSheetController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {

    private var entries = AppExceptionsConfig.load()
    private let table = NSTableView()
    private let addRemove = NSSegmentedControl()
    private let contentWidth: CGFloat = 380 /// The sheet is this + 20pt padding on each side

    override func loadView() {

        /// Title
        let title = NSTextField(labelWithString: MFLocalizedString("scroll-app-filter.sheet-title", comment: "Title at the top of the App Exceptions sheet, above the list of apps."))
        title.font = .boldSystemFont(ofSize: NSFont.systemFontSize)

        /// Table
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("app"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 24
        table.allowsMultipleSelection = true
        table.usesAlternatingRowBackgroundColors = true
        table.style = .inset
        table.dataSource = self
        table.delegate = self
        let scrollView = NSScrollView()
        scrollView.documentView = table
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        /// + / –
        addRemove.segmentStyle = .smallSquare
        addRemove.trackingMode = .momentary
        addRemove.segmentCount = 2
        addRemove.setImage(NSImage(named: NSImage.addTemplateName), forSegment: 0)
        addRemove.setImage(NSImage(named: NSImage.removeTemplateName), forSegment: 1)
        addRemove.setWidth(24, forSegment: 0)
        addRemove.setWidth(24, forSegment: 1)
        addRemove.target = self
        addRemove.action = #selector(addRemoveClicked(_:))

        /// Hint
        let hint = CoolNSTextField(hintWithString: MFLocalizedString("scroll-app-filter.hint", comment: "Hint at the bottom of the App Exceptions sheet."))
        hint.lineBreakMode = .byWordWrapping
        hint.maximumNumberOfLines = 0
        hint.cell?.wraps = true
        hint.cell?.isScrollable = false
        hint.preferredMaxLayoutWidth = contentWidth /// Labels don't wrap by default and would widen the sheet to fit the hint on one line

        /// Done
        let done = NSButton(title: MFLocalizedString("scroll-app-filter.done", comment: "Button that closes the App Exceptions sheet."), target: self, action: #selector(doneClicked))
        done.keyEquivalent = "\r"
        done.bezelStyle = .rounded

        /// Layout
        let bottomRow = NSStackView(views: [addRemove, NSView(), done])
        bottomRow.orientation = .horizontal
        bottomRow.distribution = .fill
        bottomRow.alignment = .centerY

        let stack = NSStackView(views: [title, scrollView, hint, bottomRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            scrollView.widthAnchor.constraint(equalToConstant: contentWidth),
            scrollView.heightAnchor.constraint(equalToConstant: 200),
            hint.widthAnchor.constraint(equalToConstant: contentWidth),
            bottomRow.widthAnchor.constraint(equalToConstant: contentWidth),
        ])

        /// Padding
        ///     Using required constraints instead of `NSStackView.edgeInsets`, since those are only priority 250. The sheet window starts out at zero size and only grows until the required constraints are met, which drops the insets. [Nov 2026]
        let padding: CGFloat = 20
        let view = NSView()
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: padding),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -padding),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: padding),
            stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -padding),
            stack.widthAnchor.constraint(equalToConstant: contentWidth),
        ])
        self.view = view
        updateRemoveEnabled()
    }

    // MARK: Actions

    private func commit() {
        AppExceptionsConfig.commit(entries)
        table.reloadData()
        updateRemoveEnabled()
    }

    @objc private func doneClicked() {
        presentingViewController?.dismiss(self)
    }

    @objc private func addRemoveClicked(_ sender: NSSegmentedControl) {
        if sender.selectedSegment == 0 {
            showAddMenu(below: sender)
        } else {
            let selected = table.selectedRowIndexes
            entries = entries.enumerated().filter { !selected.contains($0.offset) }.map { $0.element }
            commit()
        }
    }

    private func updateRemoveEnabled() {
        addRemove.setEnabled(table.selectedRowIndexes.count > 0, forSegment: 1)
    }

    private func showAddMenu(below control: NSView) {

        let menu = NSMenu()

        /// Running apps
        let ownBundleIDs: Set<String> = [kMFBundleIDApp, kMFBundleIDHelper]
        let running = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .map { app -> (AppFilterEntry, NSRunningApplication) in
                /// Apps without a bundleID (e.g. Minecraft Java Edition) are matched by their executable path
                (AppFilterEntry(bundleID: app.bundleIdentifier, path: app.bundleIdentifier == nil ? app.executableURL?.path : nil), app)
            }
            .filter { entry, _ in
                !ownBundleIDs.contains(entry.bundleID ?? "") && !entries.contains(entry)
                && (entry.bundleID != nil || entry.path != nil)
            }
            .sorted { ($0.1.localizedName ?? "").localizedCaseInsensitiveCompare($1.1.localizedName ?? "") == .orderedAscending }

        if !running.isEmpty {
            let header = NSMenuItem(title: MFLocalizedString("scroll-app-filter.add.running-header", comment: "Section header in the menu for adding apps to the App Exceptions list."), action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for (entry, app) in running {
                let item = NSMenuItem(title: app.localizedName ?? entry.displayName, action: #selector(addRunningApp(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = entry.dict
                let icon = (app.icon ?? entry.icon).copy() as! NSImage
                icon.size = NSSize(width: 16, height: 16)
                item.image = icon
                menu.addItem(item)
            }
            menu.addItem(.separator())
        }

        let choose = NSMenuItem(title: MFLocalizedString("scroll-app-filter.add.choose", comment: "Menu item that opens a file picker for adding an app to the App Exceptions list."), action: #selector(chooseApp), keyEquivalent: "")
        choose.target = self
        menu.addItem(choose)

        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: control.bounds.height + 2), in: control)
    }

    @objc private func addRunningApp(_ sender: NSMenuItem) {
        guard let dict = sender.representedObject as? NSDictionary, let entry = AppFilterEntry(dict: dict) else { return }
        add(entry)
    }

    @objc private func chooseApp() {
        guard let window = view.window else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.beginSheetModal(for: window) { response in
            guard response == .OK else { return }
            for url in panel.urls {
                if let bundleID = Bundle(url: url)?.bundleIdentifier {
                    self.add(AppFilterEntry(bundleID: bundleID, path: nil))
                } else if let exe = Bundle(url: url)?.executableURL?.path {
                    self.add(AppFilterEntry(bundleID: nil, path: exe))
                }
            }
        }
    }

    private func add(_ entry: AppFilterEntry) {
        guard !entries.contains(entry) else { return }
        entries.append(entry)
        commit()
    }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int {
        entries.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let entry = entries[row]
        let id = NSUserInterfaceItemIdentifier("appCell")
        let cell = tableView.makeView(withIdentifier: id, owner: self) as? NSTableCellView ?? {
            let cell = NSTableCellView()
            cell.identifier = id
            let imageView = NSImageView()
            let text = NSTextField(labelWithString: "")
            text.lineBreakMode = .byTruncatingTail
            for v in [imageView, text] as [NSView] { v.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(v) }
            cell.imageView = imageView
            cell.textField = text
            NSLayoutConstraint.activate([
                imageView.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                imageView.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                imageView.widthAnchor.constraint(equalToConstant: 18),
                imageView.heightAnchor.constraint(equalToConstant: 18),
                text.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 6),
                text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }()
        cell.imageView?.image = entry.icon
        cell.textField?.stringValue = entry.displayName
        cell.toolTip = entry.bundleID ?? entry.path
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateRemoveEnabled()
    }
}
