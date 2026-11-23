// AppVersion.swift
// Single source of truth for the version shown in the About panel and Settings.

import Foundation

enum AppVersion {
    /// `CFBundleShortVersionString` from the app bundle (e.g. "0.1.1").
    static let short: String =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
}
