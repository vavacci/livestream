//
//  livestreamApp.swift
//  livestream
//
//  Created by zzz on 2026/3/31.
//

import SwiftUI

@main
struct livestreamApp: App {
    init() {
        let defaults = LiveStreamConfig.AppGroup.defaults(refresh: true)
        defaults?.set("", forKey: "recording.lastError")
        defaults?.set(false, forKey: "cmd_stop_recording")
        defaults?.synchronize()
        setupSignalHandler()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .onOpenURL { url in
                    handleIncomingURL(url)
                }
        }
    }
    
    private func handleIncomingURL(_ url: URL) {
        if LiveStreamConfig.App.enableRuntimeLogging {
            print("Raw Incoming URL: \(url.absoluteString)")
        }
        
        // Handle schemes like: livestream://action?cmd=stop
        if let host = url.host, host == "action" {
            guard let components = URLComponents(url: url, resolvingAgainstBaseURL: true),
                  let queryItems = components.queryItems else {
                return
            }
            
            if let cmd = queryItems.first(where: { $0.name == "cmd" })?.value, cmd == "stop" {
                let defaults = LiveStreamConfig.AppGroup.defaults(refresh: true)
                defaults?.set(true, forKey: "cmd_stop_recording")
                // Need to synchronize immediately for App Group
                defaults?.synchronize()
                if LiveStreamConfig.App.enableRuntimeLogging {
                    print("Received stop command via URL Scheme")
                }
            }
            return
        }

        // Handle schemes like:
        // - livestream://rtmp://host/app/stream?token=xxx
        // - livestream://start?rtmp_url=rtmp%3A%2F%2Fhost%2Fapp%2Fstream%3Ftoken%3Dxxx
        if let rtmpURL = extractRTMPURL(from: url) {
            saveRTMPURLAndRequestStart(rtmpURL)
        }
    }

    private func extractRTMPURL(from url: URL) -> String? {
        let raw = url.absoluteString.trimmingCharacters(in: .whitespacesAndNewlines)

        if let components = URLComponents(url: url, resolvingAgainstBaseURL: true),
           let value = components.queryItems?.first(where: { $0.name == "rtmp_url" || $0.name == "url" })?.value,
           LiveStreamConfig.RTMP.isValidOverrideURL(value) {
            return value
        }

        let prefix = "livestream://"
        guard raw.lowercased().hasPrefix(prefix) else { return nil }
        let embedded = String(raw.dropFirst(prefix.count)).removingPercentEncoding ?? String(raw.dropFirst(prefix.count))
        guard LiveStreamConfig.RTMP.isValidOverrideURL(embedded) else { return nil }
        return embedded
    }

    private func saveRTMPURLAndRequestStart(_ rtmpURL: String) {
        let defaultsList = LiveStreamConfig.AppGroup.availableDefaultsByGroupID(refresh: true)
        guard !defaultsList.isEmpty else { return }

        for (groupID, defaults) in defaultsList {
            defaults.set(rtmpURL, forKey: LiveStreamConfig.RTMP.userDefaultsKey)
            defaults.set(rtmpURL, forKey: LiveStreamConfig.RTMP.deepLinkLastURLKey)
            defaults.set("", forKey: LiveStreamConfig.RTMP.deepLinkLastErrorKey)
            defaults.set(true, forKey: LiveStreamConfig.RTMP.deepLinkStartCommandKey)
            defaults.set(groupID, forKey: LiveStreamConfig.AppGroup.runtimeSelectedGroupKey)
            defaults.set(Date().timeIntervalSince1970, forKey: LiveStreamConfig.AppGroup.runtimeSelectedUpdatedAtKey)
            defaults.synchronize()
        }
    }

    private func setupSignalHandler() {
        signal(SIGTERM) { _ in
            if LiveStreamConfig.App.enableRuntimeLogging {
                print("Received SIGTERM, sending stop notification to extension...")
            }
            let defaults = LiveStreamConfig.AppGroup.defaults(refresh: true)
            defaults?.set(true, forKey: "cmd_stop_recording")
            defaults?.synchronize()
            usleep(500_000)
        }
    }
    
}
