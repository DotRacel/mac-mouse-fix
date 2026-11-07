//
// --------------------------------------------------------------------------
// AboutTabController.swift
// Created for Mac Mouse Fix (https://github.com/noah-nuebling/mac-mouse-fix)
// Created by Noah Nuebling in 2022
// Licensed under the MMF License (https://github.com/noah-nuebling/mac-mouse-fix/blob/master/License)
// --------------------------------------------------------------------------
//

import Cocoa

class AboutTabController: NSViewController {

    /// Outlets and vars

    @IBOutlet weak var versionField: NSTextField!

    @IBOutlet weak var moneyCell: NSView!
    @IBOutlet weak var moneyCellLink: Hyperlink!
    @IBOutlet weak var moneyCellImage: NSImageView!

    /// IBActions

    @IBAction func sendEmail(_ sender: Any) {

        /// Create alert

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = MFLocalizedString("mail-alert.title", comment: "")
        alert.informativeText = MFLocalizedString("mail-alert.body", comment: "")
//        alert.showsSuppressionButton = true
        let sendButton = alert.addButton(withTitle: MFLocalizedString("mail-alert.send", comment: ""))
        let backButton = alert.addButton(withTitle: MFLocalizedString("mail-alert.back", comment: ""))
        sendButton.keyEquivalent = IBUtility.keyChar(forLiteral: "return")!
        backButton.keyEquivalent = IBUtility.keyChar(forLiteral: "escape")!

        /// Set mail icon

        if let mailURL = NSWorkspace.shared.urlForApplication(toOpen: URL(string: "mailto:noah.n.public@gmail.com")!) {

            let mailPath: String
            if #available(macOS 13.0, *) {
                mailPath = mailURL.path(percentEncoded: false)
            } else {
                mailPath = mailURL.path
            }
            let mailIcon = NSWorkspace.shared.icon(forFile: mailPath)

            alert.icon = mailIcon
        }

        /// Display alert
        guard let window = MainAppState.shared.window else { return }
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn {
                NSWorkspace.shared.open(URL(string: "mailto:noah.n.public@gmail.com")!)
            }
        }
    }

    /// Init

    override func viewDidLoad() {
        super.viewDidLoad()

        /// Store self in MainAppState for global access

        MainAppState.shared.aboutTabController = self

        // TODO: Links to Acknowledgements, Readme and Website should probably be localized.

        /// Set up versionField
        /// Notes:
        ///  - Explanation for `let versionFormatExists =` logic: If the key doesn't exist in Localizable.strings, then `MFLocalizedStringgg()` returns the key. But bartycrouch (I think) automatically creates the key and initializes it to emptyString.
        ///     (Note: Don't use MFLocalizedStringggg real name in comments or BartyCrouch gets confused.)
        ///  - We're handling the case that the `app-version` key doesn't exist here, because we're adding the version-format stuff right before the 3.0.0 release, and the Korean and Chinese translations don't contain the 'app-version' key, yet.

        let versionFormat = MFLocalizedString("app-version", comment: "Note: %@ will be the app version, e.g. '3.0.0 (22027)'")
        let versionFormatExists = versionFormat.count != 0 && versionFormat != "app-version"
        let versionNumbers = "\(Locator.bundleVersionShort()) (\(Locator.bundleVersion()))"
        versionField.stringValue = versionFormatExists ? String(format: versionFormat, versionNumbers) : versionNumbers
    }
}
