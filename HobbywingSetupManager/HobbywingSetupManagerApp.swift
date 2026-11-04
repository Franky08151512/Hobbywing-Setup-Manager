import SwiftUI
import UIKit
import WebKit

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

    final class Coordinator: NSObject, WKUIDelegate, WKScriptMessageHandler {
        weak var webView: WKWebView?

        private func topViewController() -> UIViewController? {
            var controller = webView?.window?.rootViewController
            while let presented = controller?.presentedViewController {
                controller = presented
            }
            return controller
        }

        // JavaScript sends TXT and JSON file contents to this native iOS bridge.
        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard message.name == "exportFile",
                  let payload = message.body as? [String: Any],
                  let rawName = payload["name"] as? String,
                  let base64 = payload["base64"] as? String,
                  let data = Data(base64Encoded: base64, options: .ignoreUnknownCharacters),
                  !data.isEmpty else {
                showExportError("Die Exportdatei konnte nicht vorbereitet werden.")
                return
            }

            let safeName = URL(fileURLWithPath: rawName).lastPathComponent
            guard !safeName.isEmpty, safeName != ".", safeName != "/" else {
                showExportError("Der Dateiname ist ungültig.")
                return
            }

            let folderURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("HobbywingExport-\(UUID().uuidString)", isDirectory: true)
            let fileURL = folderURL.appendingPathComponent(safeName)

            do {
                try FileManager.default.createDirectory(
                    at: folderURL,
                    withIntermediateDirectories: true
                )
                try data.write(to: fileURL, options: .atomic)
                presentShareSheet(for: fileURL, temporaryFolder: folderURL)
            } catch {
                try? FileManager.default.removeItem(at: folderURL)
                showExportError("Die Datei konnte nicht gespeichert werden: \(error.localizedDescription)")
            }
        }

        private func presentShareSheet(for fileURL: URL, temporaryFolder: URL) {
            DispatchQueue.main.async {
                guard let presenter = self.topViewController() else {
                    self.showExportError("Das iOS-Teilen-Menü konnte nicht geöffnet werden.")
                    return
                }

                let activity = UIActivityViewController(
                    activityItems: [fileURL],
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
