import SwiftUI
import UIKit
import WebKit
import SQLite3
import UniformTypeIdentifiers

@main
struct HobbywingSetupManagerApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ContentView: View {
    var body: some View {
        LocalWebView()
            .ignoresSafeArea()
    }
}

struct LocalWebView: UIViewRepresentable {
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.userContentController.add(context.coordinator, name: "exportFile")
        configuration.userContentController.add(context.coordinator, name: "importDatabase")

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.uiDelegate = context.coordinator
        context.coordinator.webView = webView

        if let fileURL = Bundle.main.url(forResource: "index", withExtension: "html") {
            webView.loadFileURL(
                fileURL,
                allowingReadAccessTo: fileURL.deletingLastPathComponent()
            )
        }

        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKUIDelegate, WKScriptMessageHandler, UIDocumentPickerDelegate {
        weak var webView: WKWebView?

        private func topViewController() -> UIViewController? {
            var controller = webView?.window?.rootViewController
            while let presented = controller?.presentedViewController {
                controller = presented
            }
            return controller
        }

        // The user imports a copy of HW Link V2's visible profile index once.
        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            if message.name == "importDatabase" {
                presentDatabasePicker()
                return
            }

            guard message.name == "exportFile",
                  let payload = message.body as? [String: Any] else {
                showExportError("Die Exportdatei konnte nicht vorbereitet werden.")
                return
            }

            var filesToWrite: [(name: String, data: Data)] = []

            if let fileItems = payload["files"] as? [[String: Any]] {
                for item in fileItems {
                    guard let rawName = item["name"] as? String,
                          let base64 = item["base64"] as? String,
                          let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters),
                          !data.isEmpty else {
                        showExportError("Mindestens eine Datei im Exportpaket ist ungültig.")
                        return
                    }
                    let safeName = URL(fileURLWithPath: rawName).lastPathComponent
                    guard !safeName.isEmpty, safeName != ".", safeName != "/" else {
                        showExportError("Ein Dateiname im Exportpaket ist ungültig.")
                        return
                    }
                    filesToWrite.append((safeName, data))
                }
            } else if let rawName = payload["name"] as? String,
                      let base64 = payload["base64"] as? String,
                      let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters),
                      !data.isEmpty {
                let safeName = URL(fileURLWithPath: rawName).lastPathComponent
                guard !safeName.isEmpty, safeName != ".", safeName != "/" else {
                    showExportError("Der Dateiname ist ungültig.")
                    return
                }
                filesToWrite.append((safeName, data))
            }

            guard !filesToWrite.isEmpty else {
                showExportError("Es wurden keine gültigen Exportdateien übergeben.")
                return
            }

            let folderURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("HobbywingExport-\\(UUID().uuidString)", isDirectory: true)

            do {
                try FileManager.default.createDirectory(
                    at: folderURL,
                    withIntermediateDirectories: true
                )

                if let dbInfo = payload["hwLinkDatabase"] as? [String: Any] {
                    guard let profileName = dbInfo["profileName"] as? String,
                          let deviceKey = dbInfo["deviceKey"] as? String else {
                        throw ExportError.invalidDatabaseMetadata
                    }
                    let updatedDatabase = try makeUpdatedHWLinkDatabase(
                        profileName: profileName,
                        deviceKey: deviceKey,
                        outputFolder: folderURL
                    )
                    try storeUpdatedHWLinkDatabase(from: updatedDatabase)
                    filesToWrite.append(("MyNameTxt.sqlite", try Data(contentsOf: updatedDatabase)))
                }

                var fileURLs: [URL] = []
                for item in filesToWrite {
                    let fileURL = folderURL.appendingPathComponent(item.name)
                    try item.data.write(to: fileURL, options: .atomic)
                    fileURLs.append(fileURL)
                }
                presentShareSheet(for: fileURLs, temporaryFolder: folderURL)
            } catch {
                try? FileManager.default.removeItem(at: folderURL)
                showExportError(error.localizedDescription)
            }
        }

        private enum ExportError: LocalizedError {
            case databaseNotImported
            case invalidDatabaseMetadata
            case missingDeviceRow(String)
            case invalidNameArchive
            case databaseUpdateFailed(String)

            var errorDescription: String? {
                switch self {
                case .databaseNotImported:
                    return "Bitte zuerst über „HW-Link-Datenbank auswählen / aktualisieren“ die MyNameTxt.sqlite aus dem Ordner „HW Link V2“ auswählen."
                case .invalidDatabaseMetadata:
                    return "Die Profilangaben für den HW-Link-Datenbankeintrag fehlen."
                case .missingDeviceRow(let key):
                    return "In der ausgewählten HW-Link-Datenbank wurde kein Eintrag für dieses Gerät gefunden: \\(key). Bitte die aktuelle MyNameTxt.sqlite aus HW Link V2 auswählen."
                case .invalidNameArchive:
                    return "Die Namensliste in MyNameTxt.sqlite konnte nicht gelesen werden. Die Quelldatei wurde nicht verändert."
                case .databaseUpdateFailed(let details):
                    return "Die HW-Link-Datenbank konnte nicht aktualisiert werden: \\(details)"
                }
            }
        }

        private var storedDatabaseURL: URL {
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            return documents.appendingPathComponent("HWLinkDatabase/MyNameTxt.sqlite")
        }

        private func presentDatabasePicker() {
            DispatchQueue.main.async {
                guard let presenter = self.topViewController() else {
                    self.showExportError("Der Dateiauswahldialog konnte nicht geöffnet werden.")
                    return
                }
                let sqliteType = UTType(filenameExtension: "sqlite") ?? .data
                let picker = UIDocumentPickerViewController(
                    forOpeningContentTypes: [sqliteType, .data],
                    asCopy: true
                )
                picker.delegate = self
                picker.allowsMultipleSelection = false
                presenter.present(picker, animated: true)
            }
        }

        func documentPicker(
            _ controller: UIDocumentPickerViewController,
            didPickDocumentsAt urls: [URL]
        ) {
            guard let sourceURL = urls.first else { return }
            let accessed = sourceURL.startAccessingSecurityScopedResource()
            defer {
                if accessed { sourceURL.stopAccessingSecurityScopedResource() }
            }

            do {
                let directory = storedDatabaseURL.deletingLastPathComponent()
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true
                )
                let stagedURL = directory.appendingPathComponent("MyNameTxt.importing.sqlite")
                try? FileManager.default.removeItem(at: stagedURL)
                try FileManager.default.copyItem(at: sourceURL, to: stagedURL)
                try validateHWLinkDatabase(at: stagedURL)

                if FileManager.default.fileExists(atPath: storedDatabaseURL.path) {
                    try FileManager.default.removeItem(at: storedDatabaseURL)
                }
                try FileManager.default.moveItem(at: stagedURL, to: storedDatabaseURL)
                showImportDatabaseSuccess()
            } catch {
                showExportError("Die ausgewählte Datei ist keine lesbare HW-Link-Datenbank oder konnte nicht kopiert werden: \\(error.localizedDescription)")
            }
        }

        private func validateHWLinkDatabase(at url: URL) throws {
            var database: OpaquePointer?
            guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
                  let db = database else {
                if let database { sqlite3_close(database) }
                throw ExportError.databaseUpdateFailed("SQLite-Datei kann nicht geöffnet werden.")
            }
            defer { sqlite3_close(db) }

            var statement: OpaquePointer?
            let sql = "SELECT name, NameArray FROM Audio LIMIT 1"
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
                  let stmt = statement else {
                throw ExportError.databaseUpdateFailed("Die Tabelle Audio mit NameArray fehlt.")
            }
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_step(stmt) == SQLITE_ROW else {
                throw ExportError.databaseUpdateFailed("Die Audio-Tabelle enthält keinen Geräteeintrag.")
            }
        }

        private func storeUpdatedHWLinkDatabase(from exportURL: URL) throws {
            let directory = storedDatabaseURL.deletingLastPathComponent()
            let stagedURL = directory.appendingPathComponent("MyNameTxt.updated.sqlite")
            let backupURL = directory.appendingPathComponent("MyNameTxt.previous.sqlite")
            try? FileManager.default.removeItem(at: stagedURL)
            try? FileManager.default.removeItem(at: backupURL)

            try FileManager.default.copyItem(at: exportURL, to: stagedURL)

            if FileManager.default.fileExists(atPath: storedDatabaseURL.path) {
                try FileManager.default.moveItem(at: storedDatabaseURL, to: backupURL)
            }

            do {
                try FileManager.default.moveItem(at: stagedURL, to: storedDatabaseURL)
            } catch {
                if FileManager.default.fileExists(atPath: backupURL.path) {
                    try? FileManager.default.moveItem(at: backupURL, to: storedDatabaseURL)
                }
                throw error
            }
        }

        private func makeUpdatedHWLinkDatabase(
            profileName: String,
            deviceKey: String,
            outputFolder: URL
        ) throws -> URL {
            guard FileManager.default.fileExists(atPath: storedDatabaseURL.path) else {
                throw ExportError.databaseNotImported
            }

            let outputURL = outputFolder.appendingPathComponent("MyNameTxt.sqlite")
            try FileManager.default.copyItem(at: storedDatabaseURL, to: outputURL)

            var database: OpaquePointer?
            guard sqlite3_open(outputURL.path, &database) == SQLITE_OK,
                  let db = database else {
                if let database { sqlite3_close(database) }
                throw ExportError.databaseUpdateFailed("Die Arbeitskopie konnte nicht geöffnet werden.")
            }
            defer { sqlite3_close(db) }

            var select: OpaquePointer?
            let selectSQL = "SELECT id, NameArray FROM Audio WHERE name = ? LIMIT 1"
            guard sqlite3_prepare_v2(db, selectSQL, -1, &select, nil) == SQLITE_OK,
                  let selectStatement = select else {
                throw ExportError.databaseUpdateFailed(String(cString: sqlite3_errmsg(db)))
            }
            sqlite3_bind_text(selectStatement, 1, deviceKey, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

            guard sqlite3_step(selectStatement) == SQLITE_ROW else {
                sqlite3_finalize(selectStatement)
                throw ExportError.missingDeviceRow(deviceKey)
            }

            let rowID = sqlite3_column_int64(selectStatement, 0)
            guard let blob = sqlite3_column_blob(selectStatement, 1) else {
                sqlite3_finalize(selectStatement)
                throw ExportError.invalidNameArchive
            }
            let blobLength = Int(sqlite3_column_bytes(selectStatement, 1))
            let archiveData = Data(bytes: blob, count: blobLength)
            sqlite3_finalize(selectStatement)

            let unarchiver = try NSKeyedUnarchiver(forReadingFrom: archiveData)
            unarchiver.requiresSecureCoding = false
            guard let names = unarchiver.decodeObject(forKey: NSKeyedArchiveRootObjectKey) as? NSMutableArray else {
                unarchiver.finishDecoding()
                throw ExportError.invalidNameArchive
            }
            unarchiver.finishDecoding()

            let existing = names.compactMap { $0 as? String }
            if !existing.contains(profileName) {
                names.add(profileName)
            }

            let updatedArchive = try NSKeyedArchiver.archivedData(
                withRootObject: names,
                requiringSecureCoding: false
            )

            var update: OpaquePointer?
            let updateSQL = "UPDATE Audio SET NameArray = ? WHERE id = ?"
            guard sqlite3_prepare_v2(db, updateSQL, -1, &update, nil) == SQLITE_OK,
                  let updateStatement = update else {
                throw ExportError.databaseUpdateFailed(String(cString: sqlite3_errmsg(db)))
            }
            defer { sqlite3_finalize(updateStatement) }

            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            let bindResult = updatedArchive.withUnsafeBytes { buffer in
                sqlite3_bind_blob(
                    updateStatement,
                    1,
                    buffer.baseAddress,
                    Int32(buffer.count),
                    transient
                )
            }
            guard bindResult == SQLITE_OK else {
                throw ExportError.databaseUpdateFailed(String(cString: sqlite3_errmsg(db)))
            }
            sqlite3_bind_int64(updateStatement, 2, rowID)
            guard sqlite3_step(updateStatement) == SQLITE_DONE else {
                throw ExportError.databaseUpdateFailed(String(cString: sqlite3_errmsg(db)))
            }

            var integrity: OpaquePointer?
            guard sqlite3_prepare_v2(db, "PRAGMA integrity_check", -1, &integrity, nil) == SQLITE_OK,
                  let integrityStatement = integrity else {
                throw ExportError.databaseUpdateFailed("Integritätsprüfung konnte nicht gestartet werden.")
            }
            defer { sqlite3_finalize(integrityStatement) }
            guard sqlite3_step(integrityStatement) == SQLITE_ROW,
                  let result = sqlite3_column_text(integrityStatement, 0),
                  String(cString: result) == "ok" else {
                throw ExportError.databaseUpdateFailed("Die Integritätsprüfung der Arbeitskopie ist fehlgeschlagen.")
            }

            return outputURL
        }

        private func showImportDatabaseSuccess() {
            DispatchQueue.main.async {
                guard let presenter = self.topViewController() else { return }
                let alert = UIAlertController(
                    title: "HW-Link-Datenbank übernommen",
                    message: "Die Datenbank wurde als lokale Kopie gespeichert. Beim nächsten HW Link V2 Export wird eine aktualisierte MyNameTxt.sqlite mitgeliefert.",
                    preferredStyle: .alert
                )
                alert.addAction(UIAlertAction(title: "OK", style: .default))
                presenter.present(alert, animated: true)
            }
        }

        private func presentShareSheet(for fileURLs: [URL], temporaryFolder: URL) {
            DispatchQueue.main.async {
                guard let presenter = self.topViewController() else {
                    self.showExportError("Das iOS-Teilen-Menü konnte nicht geöffnet werden.")
                    return
                }

                let activity = UIActivityViewController(
                    activityItems: fileURLs,
                    applicationActivities: nil
                )

                activity.completionWithItemsHandler = { _, _, _, _ in
                    try? FileManager.default.removeItem(at: temporaryFolder)
                }

                if let popover = activity.popoverPresentationController {
                    popover.sourceView = presenter.view
                    popover.sourceRect = CGRect(
                        x: presenter.view.bounds.midX,
                        y: presenter.view.bounds.midY,
                        width: 1,
                        height: 1
                    )
                    popover.permittedArrowDirections = []
                }

                presenter.present(activity, animated: true)
            }
        }

        private func showExportError(_ message: String) {
            DispatchQueue.main.async {
                guard let presenter = self.topViewController() else { return }
                let alert = UIAlertController(
                    title: "Export fehlgeschlagen",
                    message: message,
                    preferredStyle: .alert
                )
                alert.addAction(UIAlertAction(title: "OK", style: .default))
                presenter.present(alert, animated: true)
            }
        }

        // JavaScript alert(), used for import/backup messages.
        func webView(
            _ webView: WKWebView,
            runJavaScriptAlertPanelWithMessage message: String,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping () -> Void
        ) {
            guard let presenter = topViewController() else {
                completionHandler()
                return
            }

            let alert = UIAlertController(
                title: "Hobbywing Setup Manager",
                message: message,
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in
                completionHandler()
            })
            presenter.present(alert, animated: true)
        }

        // JavaScript confirm(), used before deleting a saved profile.
        func webView(
            _ webView: WKWebView,
            runJavaScriptConfirmPanelWithMessage message: String,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping (Bool) -> Void
        ) {
            guard let presenter = topViewController() else {
                completionHandler(false)
                return
            }

            let alert = UIAlertController(
                title: "Hobbywing Setup Manager",
                message: message,
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "Abbrechen", style: .cancel) { _ in
                completionHandler(false)
            })
            alert.addAction(UIAlertAction(title: "Löschen", style: .destructive) { _ in
                completionHandler(true)
            })
            presenter.present(alert, animated: true)
        }

        // JavaScript prompt(), used when renaming a profile.
        func webView(
            _ webView: WKWebView,
            runJavaScriptTextInputPanelWithPrompt prompt: String,
            defaultText: String?,
            initiatedByFrame frame: WKFrameInfo,
            completionHandler: @escaping (String?) -> Void
        ) {
            guard let presenter = topViewController() else {
                completionHandler(nil)
                return
            }

            let alert = UIAlertController(
                title: "Profil umbenennen",
                message: prompt,
                preferredStyle: .alert
            )
            alert.addTextField { textField in
                textField.text = defaultText
                textField.clearButtonMode = .whileEditing
                textField.autocapitalizationType = .sentences
            }
            alert.addAction(UIAlertAction(title: "Abbrechen", style: .cancel) { _ in
                completionHandler(nil)
            })
            alert.addAction(UIAlertAction(title: "Speichern", style: .default) { _ in
                completionHandler(alert.textFields?.first?.text)
            })
            presenter.present(alert, animated: true)
        }
    }
}
