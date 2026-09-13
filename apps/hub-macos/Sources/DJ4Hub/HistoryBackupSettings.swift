import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct HistoryBackupDisplayState {
    var directory = ""
    var enabled = false
    var lastTime = "尚未备份"
    var operationMessage = ""
    var statusError = ""
    var message: String { statusError.isEmpty ? operationMessage : statusError }

    mutating func beginOperation() {
        operationMessage = ""
    }
    mutating func operationFailed(_ error: Error) {
        operationMessage = "操作失败：\(error.localizedDescription)"
    }
    mutating func applyRefresh(_ result: HubValue) {
        directory = result["directory"].raw as? String ?? ""
        enabled = result["enabled"].bool
        if let date = HistoryPresentation.date(result["last_time"].text), date.timeIntervalSince1970 > 0 {
            lastTime = date.formatted(date: .abbreviated, time: .shortened)
        } else {
            lastTime = "尚未备份"
        }
        if let error = result["error"].raw as? String, !error.isEmpty {
            statusError = "备份失败：\(error)"
        } else {
            statusError = ""
        }
    }
}

struct HistoryBackupSettings: View {
    @ObservedObject var service: HubService
    @State private var display = HistoryBackupDisplayState()
    @State private var busy = false

    var body: some View {
        SettingsSection(title: "通信记录备份") {
            Text("主数据库保留在本机。请选择 iCloud Drive、Documents 或其他云盘中的文件夹存放完整快照。备份包含电话号码和短信内容，请使用自己的私密目录。")
                .font(.callout).foregroundStyle(.secondary)
            SettingRow(title: "备份位置", detail: display.directory.isEmpty ? "尚未选择，备份未启用" : display.directory) {
                Button("选择文件夹…", systemImage: "folder") { chooseDirectory() }
            }
            SettingRow(title: "自动备份", detail: "服务运行时每 30 分钟检查变化；保留本机最近 10 份，较早版本自动删除") {
                Toggle("自动备份", isOn: Binding(get: { display.enabled }, set: { value in
                    perform(["action": "configure", "path": display.directory, "enabled": value])
                })).labelsHidden().disabled(display.directory.isEmpty)
            }
            DetailRow(title: "最近备份", value: display.lastTime)
            HStack {
                Button("立即备份", systemImage: "externaldrive.badge.timemachine") { perform(["action": "backup"]) }.disabled(display.directory.isEmpty)
                Button("打开备份目录", systemImage: "folder") { NSWorkspace.shared.open(URL(fileURLWithPath: display.directory)) }.disabled(display.directory.isEmpty)
                Spacer()
                Button("从备份恢复…", systemImage: "arrow.counterclockwise") { chooseRestore() }
            }
            if busy { ProgressView().controlSize(.small) }
            if !display.message.isEmpty { Text(display.message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            Text("备份成功表示文件已生成，不代表云盘已上传。恢复会先保存本机安全副本，再补回缺失记录，不覆盖已有记录。恢复不会导入短信到 SIM 卡。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .disabled(busy)
        .task { await refresh() }
        .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { _ in
            if !busy { Task { await refresh() } }
        }
    }
    private func refresh() async {
        do {
            let result = try await service.request("api/history/backup")
            display.applyRefresh(result)
        } catch { display.statusError = "无法读取备份设置：\(error.localizedDescription)" }
    }
    private func perform(_ body: [String: Any]) {
        guard !busy else { return }
        busy = true
        display.beginOperation()
        Task {
            defer { busy = false }
            do {
                let result = try await service.request("api/history/backup", method: "POST", body: body)
                display.operationMessage = result["message"].text
                await refresh()
            } catch { display.operationFailed(error) }
        }
    }
    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.title = "选择私密的云盘备份文件夹"
        panel.message = "只在这个目录写入备份，不移动主数据库。自动备份需另外开启。"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = display.directory.isEmpty ? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first : URL(fileURLWithPath: display.directory)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        perform(["action": "configure", "path": url.path, "enabled": display.enabled])
    }
    private func chooseRestore() {
        let panel = NSOpenPanel()
        panel.title = "选择 DJ 4G Hub SQLite 备份"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "sqlite") ?? .data]
        if !display.directory.isEmpty { panel.directoryURL = URL(fileURLWithPath: display.directory) }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        confirm("从备份补回记录", "将读取 \(url.lastPathComponent)。先备份本机数据，再补回缺失记录；现有同 ID 记录不变。请在通话结束后操作。") {
            perform(["action": "restore", "path": url.path, "confirmed": true])
        }
    }
}
