import SwiftUI
import AppKit
import YandexDiskCore

private let accent = Color(red: 0.25, green: 0.38, blue: 0.92)
private func bytes(_ number: Int64) -> String { ByteCountFormatter.string(fromByteCount: number, countStyle: .file) }
private func duration(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "—" }
    let value = Int(seconds)
    return value >= 3600 ? String(format: "%d:%02d:%02d", value / 3600, value / 60 % 60, value % 60) : String(format: "%d:%02d", value / 60, value % 60)
}
struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var selected = "download"
    @State private var cancelAlert = false
    @State private var debounce: Task<Void, Never>?
    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.down.circle.fill").font(.system(size: 29)).foregroundStyle(accent)
                    VStack(alignment: .leading, spacing: 2) { Text("DISK").font(.system(size: 13, weight: .heavy, design: .rounded)); Text("DOWNLOADER").font(.system(size: 9, weight: .semibold)).tracking(1.2).foregroundStyle(.secondary) }
                }.padding(.bottom, 30)
                nav("download", model.t("Downloads", "Загрузки"), "arrow.down.to.line")
                nav("history", model.t("History", "История"), "clock.arrow.circlepath")
                nav("settings", model.t("Settings", "Настройки"), "slider.horizontal.3")
                Spacer()
                Label(model.t("Direct & private", "Напрямую с Диска"), systemImage: "lock.shield").font(.caption).foregroundStyle(.secondary)
                Text(model.t("Independent open-source app", "Независимый open-source проект")).font(.system(size: 10)).foregroundStyle(.tertiary)
                Text("v1.0.1").font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary).padding(.top, 4)
            }.padding(22).frame(width: 195).background(.ultraThinMaterial)
            Divider()
            Group {
                if selected == "history" { HistoryView(onRepeat: { selected = "download" }) }
                else if selected == "settings" { SettingsView() }
                else { downloadView }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }.frame(minWidth: 850, minHeight: 660).tint(accent)
            .alert(model.t("Cancel download?", "Отменить загрузку?"), isPresented: $cancelAlert) {
                Button(model.t("Keep Downloading", "Продолжить"), role: .cancel) {}
                Button(model.t("Cancel Download", "Отменить загрузку"), role: .destructive) { model.cancel() }
            } message: { Text(model.t("Completed files will stay in your folder.", "Уже скачанные файлы останутся в папке.")) }
    }
    private func nav(_ id: String, _ title: String, _ icon: String) -> some View {
        Button { selected = id } label: {
            Label(title, systemImage: icon).font(.system(size: 13, weight: selected == id ? .semibold : .regular)).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 11)
                .foregroundStyle(selected == id ? accent : Color.primary)
                .background(selected == id ? accent.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 9))
        }.buttonStyle(.plain)
    }
    private var downloadView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(model.t("Your files. On your Mac.", "Ваши файлы. На вашем Mac.")).font(.system(size: 27, weight: .bold))
                    Text(model.t("Download public Yandex Disk folders, one file at a time.", "Скачивайте публичные папки Яндекс Диска с сохранением структуры.")).font(.system(size: 13)).foregroundStyle(.secondary)
                }.padding(.bottom, 4)
                VStack(alignment: .leading, spacing: 16) {
                    HStack { step("1", model.t("Public link", "Публичная ссылка")); Spacer(); Button { model.link = NSPasteboard.general.string(forType: .string) ?? ""; debounce?.cancel(); model.inspect() } label: { Label(model.t("Paste", "Вставить"), systemImage: "doc.on.clipboard") }.disabled(model.busy).buttonStyle(.borderless) }
                    HStack(spacing: 8) {
                        Image(systemName: "link").foregroundStyle(.secondary)
                        TextField(model.t("Paste Yandex Disk public link", "Вставьте публичную ссылку Яндекс Диска"), text: $model.link).textFieldStyle(.plain).onSubmit { debounce?.cancel(); model.inspect() }
                            .disabled(model.busy)
                            .onChange(of: model.link) { newValue in
                                debounce?.cancel()
                                guard !model.busy else { return }
                                model.manifest = nil; model.phase = .idle
                                guard newValue.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("https://") else { return }
                                debounce = Task { do { try await Task.sleep(nanoseconds: 800_000_000); if !Task.isCancelled { model.inspect() } } catch {} }
                            }
                        Button(model.t("Inspect", "Проверить")) { debounce?.cancel(); model.inspect() }.disabled(model.busy || model.link.isEmpty)
                    }.padding(12).background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
                    if model.phase == .scanning {
                        HStack { ProgressView().controlSize(.small); Text(model.t("Reading folders… \(model.scanned) files found", "Чтение папок… найдено файлов: \(model.scanned)")).foregroundStyle(.secondary); Spacer(); Button(model.t("Cancel", "Отмена")) { model.cancel() } }.font(.caption)
                    } else if let manifest = model.manifest {
                        HStack(spacing: 12) {
                            Image(systemName: manifest.isDirectory ? "folder.fill" : "doc.fill").font(.system(size: 30)).foregroundStyle(accent.opacity(0.8))
                            VStack(alignment: .leading, spacing: 4) {
                                Text(manifest.name).font(.system(size: 14, weight: .semibold)).lineLimit(2)
                                Text(resourceSummary(manifest)).font(.caption).foregroundStyle(.secondary)
                            }; Spacer(); Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        }.padding(.top, 2)
                    }
                    Divider()
                    HStack { step("2", model.t("Save to", "Куда сохранить")); Spacer(); Button(model.t("Choose Folder", "Выбрать папку")) { model.chooseFolder() }.disabled(model.busy) }
                    Label(model.preferences.destinationPath.isEmpty ? model.t("Choose a folder on your Mac", "Выберите папку на Mac") : model.preferences.destinationPath, systemImage: "folder")
                        .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                }.padding(22).card()
                if let manifest = model.manifest, !manifest.warnings.isEmpty {
                    DisclosureGroup(model.t("Name adjustments and skipped items: \(manifest.warnings.count)", "Изменённые имена и пропущенные элементы: \(manifest.warnings.count)")) {
                        ForEach(Array(manifest.warnings.enumerated()), id: \.offset) { _, warning in
                            Text(warning).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 3)
                        }
                    }.font(.caption).padding(14).card()
                }
                if let error = model.error { Label(error, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.red).textSelection(.enabled) }
                if [.downloading, .paused, .cancelling, .completed, .cancelled].contains(model.phase), model.manifest != nil { progressCard }
                else {
                    Button { debounce?.cancel(); model.download() } label: { Label(model.t("Download", "Скачать"), systemImage: "arrow.down").font(.system(size: 14, weight: .semibold)).frame(maxWidth: .infinity).padding(.vertical, 10) }.buttonStyle(.borderedProminent).controlSize(.large).disabled(model.phase != .ready || model.preferences.destinationPath.isEmpty)
                    HStack(spacing: 7) { Image(systemName: "checkmark.shield"); Text(model.t("No sign-in. Individual file downloads. Original folder structure.", "Без входа в аккаунт. Пофайловая загрузка. Исходная структура.")) }.font(.system(size: 11)).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                }
                if !model.failures.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack { Text(model.t("Files needing attention", "Не удалось скачать")).font(.headline); Spacer(); Button(model.t("Retry Failed Downloads", "Повторить неудачные")) { model.download(retryFailed: true) }.disabled(model.busy) }
                        ForEach(model.failures) { failure in VStack(alignment: .leading, spacing: 3) { Text(failure.file.id).font(.caption).bold(); Text(failure.message).font(.caption).foregroundStyle(.secondary) }.textSelection(.enabled); Divider() }
                    }.padding(18).card()
                }
            }.padding(30)
        }
    }
    private func resourceSummary(_ manifest: Manifest) -> String {
        let count = "\(manifest.files.count) " + model.t("files", "файлов")
        let size = manifest.hasKnownSize ? bytes(manifest.totalSize) : model.t("Size unknown", "Размер неизвестен")
        let kind = manifest.isDirectory ? model.t("Folder", "Папка") : model.t("File", "Файл")
        return [count, size, kind].joined(separator: "  ·  ")
    }
    private func step(_ number: String, _ label: String) -> some View {
        HStack(spacing: 9) { Text(number).font(.system(size: 10, weight: .bold, design: .rounded)).frame(width: 21, height: 21).background(accent.opacity(0.10), in: Circle()).foregroundStyle(accent); Text(label).font(.system(size: 13, weight: .semibold)) }
    }
    private var progressCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label(status, systemImage: model.phase == .completed ? (model.failures.isEmpty && model.error == nil ? "checkmark.circle.fill" : "exclamationmark.circle") : model.phase == .paused ? "pause.circle" : "arrow.down.circle")
                    .font(.system(size: 16, weight: .semibold))
                Spacer(); Text(String(format: "%.0f%%", model.fraction * 100)).font(.system(size: 20, weight: .semibold, design: .rounded)).monospacedDigit()
            }
            ProgressView(value: model.fraction).tint(accent)
            HStack(alignment: .top) {
                metric(model.t("Files", "Файлы"), "\(model.completed) / \(model.manifest?.files.count ?? 0)")
                Spacer(); metric(model.t("Downloaded", "Загружено"), bytes(model.progressBytes) + " / " + (model.manifest?.hasKnownSize == true ? bytes(model.totalBytes) : "—"))
                Spacer(); metric(model.t("Speed", "Скорость"), bytes(Int64(model.speed)) + "/s")
                Spacer(); metric(model.busy ? model.t("Remaining", "Осталось") : model.t("Elapsed", "Время"), model.busy ? (model.speed > 0 && model.manifest?.hasKnownSize == true ? duration(Double(max(0, model.totalBytes - model.progressBytes)) / model.speed) : "—") : duration(model.elapsed))
            }
            if model.skipped > 0 { Text(model.t("\(model.skipped) existing files verified and skipped", "Проверено и пропущено существующих файлов: \(model.skipped)")).font(.caption).foregroundStyle(.secondary) }
            ForEach(model.currentFiles.keys.sorted(), id: \.self) { key in Text(model.currentFiles[key] ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
            if !model.notice.isEmpty { Text(model.notice).font(.caption).foregroundStyle(.secondary) }
            Divider()
            HStack {
                if model.phase == .downloading { Button { model.pause() } label: { Label(model.t("Pause", "Пауза"), systemImage: "pause.fill") } }
                if model.phase == .paused { Button { model.resume() } label: { Label(model.t("Resume", "Продолжить"), systemImage: "play.fill") }.buttonStyle(.borderedProminent) }
                if model.busy { Spacer(); Button(model.t("Cancel", "Отменить"), role: .destructive) { cancelAlert = true }.disabled(model.phase == .cancelling) }
                else {
                    Text(model.t("Errors: \(model.failures.count + (model.manifest?.skippedItems ?? 0))", "Ошибок и пропусков: \(model.failures.count + (model.manifest?.skippedItems ?? 0))")).font(.caption).foregroundStyle(.secondary)
                    Spacer(); Button(model.t("Another Download", "Новая загрузка")) { model.reset() }; Button(model.t("Open in Finder", "Открыть в Finder")) { model.openOutput() }.buttonStyle(.borderedProminent)
                }
            }
        }.padding(22).card()
    }
    private var status: String {
        switch model.phase {
        case .paused: return model.t("Download paused", "Загрузка приостановлена")
        case .cancelling: return model.t("Cancelling…", "Отмена…")
        case .cancelled: return model.t("Download cancelled", "Загрузка отменена")
        case .completed: return model.failures.isEmpty && model.error == nil && model.manifest?.skippedItems == 0 ? model.t("Download completed", "Загрузка завершена") : model.t("Completed with errors", "Завершено с ошибками")
        default: return model.t("Downloading", "Скачивание")
        }
    }
    private func metric(_ label: String, _ value: String) -> some View { VStack(alignment: .leading, spacing: 6) { Text(label).font(.system(size: 10)).foregroundStyle(.secondary); Text(value).font(.system(size: 13, weight: .medium, design: .rounded)).monospacedDigit() } }
}
private extension View {
    func card() -> some View { self.background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 15)).overlay(RoundedRectangle(cornerRadius: 15).stroke(Color.primary.opacity(0.07), lineWidth: 1)) }
}

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        Form {
            Section(model.t("General", "Основные")) {
                LabeledContent(model.t("Default folder", "Папка по умолчанию")) { Button(model.t("Choose Folder", "Выбрать папку")) { model.chooseFolder() }.disabled(model.busy) }
                Text(model.preferences.destinationPath.isEmpty ? model.t("No folder selected", "Папка не выбрана") : model.preferences.destinationPath).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                Toggle(model.t("Open folder after completion", "Открывать папку после завершения"), isOn: $model.preferences.openAfter)
                Toggle(model.t("Show notifications", "Показывать уведомления"), isOn: $model.preferences.notifications)
            }
            Section(model.t("Downloads", "Загрузки")) {
                Picker(model.t("Concurrent downloads", "Одновременные загрузки"), selection: $model.preferences.concurrent) { ForEach([1, 2, 3, 5, 8], id: \.self) { Text("\($0)").tag($0) } }
                Stepper(model.t("Metadata retries: \(model.preferences.retries)", "Повторов чтения папки: \(model.preferences.retries)"), value: $model.preferences.retries, in: 0...8)
                Toggle(model.t("Skip matching existing files", "Пропускать совпадающие файлы"), isOn: $model.preferences.skipExisting)
                Toggle(model.t("Verify downloaded file size", "Проверять размер файла"), isOn: $model.preferences.verifySize)
                Toggle(model.t("Verify checksum when available", "Проверять контрольную сумму"), isOn: $model.preferences.verifyChecksum)
                Text(model.t("File errors are skipped immediately. Use Retry Failed Downloads after the queue finishes. Conflicting files receive numbered names.", "При ошибке файл пропускается. Повторить неудачные можно после завершения очереди. При совпадении имён копия получает номер.")).font(.caption).foregroundStyle(.secondary)
            }
            Section(model.t("Appearance & language", "Оформление и язык")) {
                Picker(model.t("Appearance", "Тема"), selection: $model.preferences.appearance) { Text(model.t("System", "Системная")).tag("system"); Text(model.t("Light", "Светлая")).tag("light"); Text(model.t("Dark", "Тёмная")).tag("dark") }
                Picker(model.t("Language", "Язык"), selection: $model.preferences.language) { Text("English").tag("en"); Text("Русский").tag("ru") }
            }
        }.formStyle(.grouped).frame(minWidth: 530, minHeight: 620)
    }
}

struct HistoryView: View {
    @EnvironmentObject var model: AppModel
    var onRepeat: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(model.t("Download history", "История загрузок")).font(.system(size: 27, weight: .bold))
            if model.history.isEmpty {
                Spacer(); VStack(spacing: 12) { Image(systemName: "clock.arrow.circlepath").font(.system(size: 38)).foregroundStyle(.tertiary); Text(model.t("Your downloads will appear here", "Здесь появятся ваши загрузки")).foregroundStyle(.secondary) }.frame(maxWidth: .infinity); Spacer()
            } else {
                List {
                    ForEach(model.history) { item in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack { Text(item.name).font(.headline); Spacer(); Text(status(item.status)).font(.caption).foregroundStyle(item.status == "completed" ? .green : .orange) }
                            Text(item.date.formatted(date: .abbreviated, time: .shortened) + "  ·  \(item.files) " + model.t("files", "файлов") + "  ·  " + bytes(item.bytes)).font(.caption).foregroundStyle(.secondary)
                            Text(item.destination).font(.caption).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                            HStack { Button(model.t("Open in Finder", "Открыть в Finder")) { model.openHistory(item) }; Button(model.t("Repeat", "Повторить")) { model.repeatHistory(item); onRepeat() }.disabled(model.busy); Spacer(); Button(role: .destructive) { model.history.removeAll { $0.id == item.id } } label: { Image(systemName: "trash") }.help(model.t("Remove history entry only", "Удалить только запись из истории")) }
                        }.padding(.vertical, 12)
                    }
                }.listStyle(.plain)
            }
        }.padding(30)
    }
    func status(_ value: String) -> String { value == "completed" ? model.t("Completed", "Готово") : value == "cancelled" ? model.t("Cancelled", "Отменено") : model.t("With errors", "С ошибками") }
}
