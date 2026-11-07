//
// --------------------------------------------------------------------------
// ScrollTabMirroring.swift
// Created for Mac Mouse Fix (https://github.com/noah-nuebling/mac-mouse-fix)
// Licensed under the MMF License (https://github.com/noah-nuebling/mac-mouse-fix/blob/master/License)
// --------------------------------------------------------------------------
//

/// UI for the experimental iPhone Mirroring option [Nov 2026]
///     Config: `Scroll.iPhoneMirroring` (Bool), `Scroll.iPhoneMirroringSpeed` ("low" / "medium" / "high")
///     The Helper side lives in `Scroll.m` (search for 'iPhone Mirroring'). See there for how it works.
///     Built in code instead of in `Main.storyboard` to keep the diff small and mergeable with upstream.

import Cocoa

@available(macOS 11.0, *)
extension ScrollTabController {

    /// Appends a divider and the iPhone Mirroring section to `masterStack`.
    func installMirroringSection() {

        /// Read config
        ///     Optional keys – older configs don't have them. Keep the defaults in sync with `default_config.plist`
        let isEnabled = config("Scroll.iPhoneMirroring") as? Bool ?? false
        let speed = config("Scroll.iPhoneMirroringSpeed") as? String ?? "medium"

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

        /// Toggle
        let toggle = NSButton(checkboxWithTitle: MFLocalizedString("scroll-mirroring.toggle", comment: "Checkbox in the Scrolling tab. Turns on an experimental feature that makes the scroll wheel scroll smoothly in Apple's iPhone Mirroring app. Use Apple's official name for 'iPhone Mirroring' in your language."), target: self, action: #selector(mirroringToggleChanged(_:)))
        toggle.state = isEnabled ? .on : .off
        toggle.setAccessibilityIdentifier("axScrollingMirroringToggle")

        /// Hint (Indented under the checkbox, like the 'Trackpad Simulation' hint in Main.storyboard)
        let hintRaw = MFLocalizedString("scroll-mirroring.hint", comment: "Hint below the 'iPhone Mirroring (Experimental)' checkbox in the Scrolling tab. Mac Mouse Fix needs a trackpad (built-in or Magic Trackpad) to be connected for this to work, and 'Smooth Scrolling' to be on.")
        let hint = CoolNSTextField(hintWithAttributedString: MarkdownParser.attributedString(withCoolMarkdown: hintRaw, fillOutBase: false)!)
        hint.translatesAutoresizingMaskIntoConstraints = false
        hint.cell?.wraps = true
        hint.setContentCompressionResistancePriority(.init(999), for: .horizontal) /// Same as the other hints after `applyHardcodedTabWidth()`
        hint.setContentHuggingPriority(.init(1000), for: .vertical)

        /// Speed picker
        ///     Reuse the titles from the main 'Speed' picker so we get its translations for free.
        let speedLabel = NSTextField(labelWithString: MFLocalizedString("scroll-mirroring.speed-label", comment: "Label in the Scrolling tab, below the 'iPhone Mirroring (Experimental)' checkbox. Followed by a popup button for choosing Low / Medium / High scroll speed, which only applies inside iPhone Mirroring."))
        let speedPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        for identifier in ["low", "medium", "high"] {
            let title = speedPicker.itemArray.first(where: { $0.identifier?.rawValue == identifier })?.title ?? identifier
            speedPopup.addItem(withTitle: title)
            speedPopup.lastItem?.identifier = NSUserInterfaceItemIdentifier(identifier)
        }
        speedPopup.selectItem(at: speedPopup.itemArray.firstIndex(where: { $0.identifier?.rawValue == speed }) ?? 1)
        speedPopup.target = self
        speedPopup.action = #selector(mirroringSpeedChanged(_:))
        speedPopup.isEnabled = isEnabled
        speedPopup.setAccessibilityIdentifier("axScrollingMirroringSpeedPicker")
        mirroringSpeedPopup = speedPopup

        let speedRow = NSStackView(views: [speedLabel, speedPopup])
        speedRow.orientation = .horizontal
        speedRow.alignment = .firstBaseline
        speedRow.spacing = 8

        /// Indent hint and speed row
        let indented = NSStackView(views: [hint, speedRow])
        indented.orientation = .vertical
        indented.alignment = .leading
        indented.spacing = 8
        indented.edgeInsets = NSEdgeInsets(top: 0, left: 20, bottom: 0, right: 0) /// Keep in sync with `indent` below
        indented.translatesAutoresizingMaskIntoConstraints = false

        /// Section
        let section = NSStackView(views: [toggle, indented])
        section.orientation = .vertical
        section.alignment = .leading
        section.spacing = 4
        section.translatesAutoresizingMaskIntoConstraints = false

        /// Don't let anything absorb extra height [Nov 2026]
        ///     `TabViewController.resizeWindowToFit()` measures the tab inside a huge (~100000 pt tall) window. NSStackView defaults to `.gravityAreas` distribution and a vertical content hugging of 250 *as a view* (`setHuggingPriority` only controls how it hugs its own arranged views),
        ///     so the section would absorb all the extra height and the window would become ~100000 pt tall. (That also crashed in `NSView.takeScreenshot()` when switching tabs.)
        ///     -> Use `.fill` and hug at 1000 like the views in Main.storyboard.
        for stack in [section, indented, speedRow] {
            stack.distribution = .fill
            stack.setHuggingPriority(.init(1000), for: .vertical)
            stack.setContentHuggingPriority(.init(1000), for: .vertical)
        }
        divider.setContentHuggingPriority(.init(1000), for: .vertical)
        ///     The real culprit was the checkbox: `NSButton(checkboxWithTitle:)` gets a vertical hugging of 250, while the checkboxes in Main.storyboard have 1000. It stretched to ~99500 pt. (Found by logging all views taller than 1000 pt inside `resizeWindowToFit()`.)
        for control in [toggle, speedLabel, speedPopup] as [NSView] {
            control.setContentHuggingPriority(.init(1000), for: .vertical)
            control.setContentHuggingPriority(.init(1000), for: .horizontal)
        }
        speedPopup.setContentCompressionResistancePriority(.init(1000), for: .vertical) /// Otherwise it gets squished to the label's height (18 instead of 22 pt)

        masterStack.addArrangedSubview(divider)
        masterStack.addArrangedSubview(section)
        divider.widthAnchor.constraint(equalTo: masterStack.widthAnchor).isActive = true
        section.widthAnchor.constraint(equalTo: masterStack.widthAnchor).isActive = true
        indented.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true

        /// Give the wrapping hint a fixed width
        ///     Otherwise `TabViewController.resizeWindowToFit()` (which measures the tab inside a huge window) squeezes the hint to almost zero width, so it wraps after every word and makes the tab extremely tall. [Nov 2026]
        ///     The tab width is fixed by `applyHardcodedTabWidth()`, which runs before this, so we can measure it here – like the `preciseSection` code in ScrollTabController does.
        let indent: CGFloat = 20
        hint.widthAnchor.constraint(equalTo: indented.widthAnchor, constant: -indent).isActive = true
        self.view.needsLayout = true
        self.view.layoutSubtreeIfNeeded()
        hint.preferredMaxLayoutWidth = masterStack.frame.width - indent
    }

    @objc func mirroringToggleChanged(_ sender: NSButton) {
        let isEnabled = sender.state == .on
        mirroringSpeedPopup?.isEnabled = isEnabled
        setConfig("Scroll.iPhoneMirroring", isEnabled as NSObject)
        commitConfig()
    }

    @objc func mirroringSpeedChanged(_ sender: NSPopUpButton) {
        guard let speed = sender.selectedItem?.identifier?.rawValue else { assert(false); return }
        setConfig("Scroll.iPhoneMirroringSpeed", speed as NSObject)
        commitConfig()
    }
}

