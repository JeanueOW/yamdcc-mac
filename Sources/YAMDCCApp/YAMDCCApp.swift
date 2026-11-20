// YAMDCCApp.swift
// Application entry point.

import SwiftUI
import AppKit
import YAMDCCKit

@main
struct YAMDCCApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView()
                .environmentObject(state)
        }
        .defaultSize(width: 760, height: 780)
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("打开配置…") { state.presentOpenConfig() }
                    .keyboardShortcut("o", modifiers: [.command])
                Button("导入配置…") { state.presentImportConfig() }
                Button("另存为…") { state.saveConfigAs() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                Divider()
                Button("显示配置文件夹") {
                    NSWorkspace.shared.activateFileViewerSelecting([AppPaths.configsDirectory])
                }
            }
            CommandGroup(replacing: .appInfo) {
                Button("关于 YAMDCC for macOS") {
                    NSApp.orderFrontStandardAboutPanel(options: [
                        .applicationName: "YAMDCC",
                        .applicationVersion: "1.0.0",
                        .credits: NSAttributedString(string:
                            "MSI 风扇与 EC 控制。基于 Sparronator9999/YAMDCC (GPL-3.0)。"),
                    ])
                }
            }
            CommandMenu("风扇") {
                Button(state.backendInfo.isSimulated ? "应用到模拟 EC" : "应用配置") { state.apply() }
                    .keyboardShortcut("a", modifiers: [.command, .shift])
                    .disabled(state.config == nil || state.isApplying)
                Button(state.backendInfo.isSimulated ? "刷新模拟状态" : "从硬件刷新") { state.revertToHardware() }
                    .keyboardShortcut("r", modifiers: [.command])
                Divider()
                Button("保存配置") { state.saveConfig() }
                    .keyboardShortcut("s", modifiers: [.command])
            }
        }

        Settings {
            SettingsView()
                .environmentObject(state)
                .frame(width: 600, height: 560)
        }
    }
}
