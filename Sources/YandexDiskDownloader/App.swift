import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    static weak var model: AppModel?
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model = Self.model, model.busy else { return .terminateNow }
        let alert = NSAlert(); alert.messageText = model.t("Stop the current download and quit?", "Остановить загрузку и выйти?")
        alert.informativeText = model.t("Completed files are kept. Incomplete files may restart next time.", "Готовые файлы сохранятся. Неполные файлы могут загружаться заново.")
        alert.addButton(withTitle: model.t("Keep Downloading", "Продолжить загрузку")); alert.addButton(withTitle: model.t("Quit", "Выйти"))
        if alert.runModal() == .alertSecondButtonReturn { model.cancel(); return .terminateNow }
        return .terminateCancel
    }
}

@main struct DownloaderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()
    var body: some Scene {
        WindowGroup("Yandex Disk Downloader") {
            ContentView().environmentObject(model).preferredColorScheme(model.colorScheme)
                .onAppear { AppDelegate.model = model }
        }.defaultSize(width: 920, height: 730)
        Settings { SettingsView().environmentObject(model).preferredColorScheme(model.colorScheme) }
    }
}
