//
//  ContentView.swift
//  livestream
//
//  Created by zzz on 2026/3/31.
//

import SwiftUI
import ReplayKit
import Combine
import UIKit

struct ContentView: View {
    private static let diagnosticSignalNames = [
        "com.xxx.livestream.broadcast.started",
        "com.xxx.livestream.broadcast.pipelineStarted",
        "com.xxx.livestream.broadcast.firstVideo",
        "com.xxx.livestream.broadcast.firstAppAudio",
        "com.xxx.livestream.broadcast.firstMicAudio",
        "com.xxx.livestream.broadcast.heartbeat",
        "com.xxx.livestream.broadcast.finished",
        "com.xxx.livestream.broadcast.failed",
        "com.xxx.livestream.broadcast.rtmpConnected",
        "com.xxx.livestream.broadcast.metadataSent",
        "com.xxx.livestream.broadcast.videoSequenceSent",
        "com.xxx.livestream.broadcast.audioSequenceSent",
        "com.xxx.livestream.broadcast.firstVideoPacketSent",
        "com.xxx.livestream.broadcast.firstAudioPacketSent",
        "com.xxx.livestream.broadcast.mediaPacketSendFailed",
        "com.xxx.livestream.broadcast.mediaPacketSendFailed.metadata",
        "com.xxx.livestream.broadcast.mediaPacketSendFailed.metadataUpdate",
        "com.xxx.livestream.broadcast.mediaPacketSendFailed.videoSequence",
        "com.xxx.livestream.broadcast.mediaPacketSendFailed.audioSequence",
        "com.xxx.livestream.broadcast.mediaPacketSendFailed.videoKey",
        "com.xxx.livestream.broadcast.mediaPacketSendFailed.video",
        "com.xxx.livestream.broadcast.mediaPacketSendFailed.audio"
    ]

    private enum UIId {
        static let rtmpURLTextField = "rtmp_url_textfield"
        static let rtmpSaveButton = "rtmp_url_save_button"
        static let rtmpResetButton = "rtmp_url_reset_button"
        static let rtmpSaveButtonLabel = "rtmp_url_save_button_label"
        static let rtmpResetButtonLabel = "rtmp_url_reset_button_label"
        static func videoPresetButton(_ id: String) -> String { "video_preset_\(id)_button" }
        static func videoPresetButtonLabel(_ id: String) -> String { "video_preset_\(id)_button_label" }
    }

    private let extensionBundleID: String = {
        if let pluginsURL = Bundle.main.builtInPlugInsURL,
           let pluginURLs = try? FileManager.default.contentsOfDirectory(
            at: pluginsURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
           ) {
            for pluginURL in pluginURLs where pluginURL.pathExtension == "appex" {
                if let bundle = Bundle(url: pluginURL),
                   let bundleID = bundle.bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !bundleID.isEmpty {
                    return bundleID
                }
            }
        }
        let base = Bundle.main.bundleIdentifier ?? "com.xxx.livestream"
        return base + ".ScreenBroadcastExtension"
    }()

    @State private var isBroadcasting: Bool = false
    @State private var lastFilePath: String = ""
    @State private var lastError: String = ""
    @State private var exportedPath: String = ""
    @State private var exportingHint: String = ""
    @State private var logs: [String] = []
    @State private var diagnosticText: String = "等待推流诊断数据…"
    @State private var lastLoggedDiagnosticText: String = ""
    @State private var rtmpURLInput: String = ""
    @State private var rtmpConfigHint: String = ""
    @State private var isEditingRTMPURL: Bool = false
    @State private var hasUnsavedRTMPURLInput: Bool = false
    @State private var videoPresetHint: String = ""
    @State private var currentVideoPresetID: String = LiveStreamConfig.Video.currentPreset.id
    @State private var isVideoPresetSectionExpanded: Bool = false
    @State private var broadcastStartTrigger: Int = 0
    @StateObject private var diagnosticNotifier = DarwinNotificationObserver(names: ContentView.diagnosticSignalNames)

    var body: some View {
        VStack(spacing: 16) {
            HStack {
//                Text("实时录屏上报")
//                    .font(.title2)
//                Spacer()

                if LiveStreamConfig.App.enableLogDisplay {
                    Button("清空日志") {
                        SharedLogger.clear()
                        logs = []
                    }
                    .font(.footnote)
                    .padding(6)
                    .background(Color.red.opacity(0.8))
                    .foregroundColor(.white)
                    .cornerRadius(4)
                }
            }

//            Text("点击下方按钮后，系统会弹出“开始广播”面板")
//                .font(.footnote)
//                .foregroundColor(.secondary)
//
//            Text("无声音时：请在系统广播面板打开“麦克风”，并确保录制的 App 本身有声音")
//                .font(.footnote)
//                .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                Button {
                    isVideoPresetSectionExpanded.toggle()
                } label: {
                    HStack(spacing: 8) {
                        Text("视频档位设置")
                            .font(.headline)
                            .foregroundColor(.primary)
                        Spacer()
                        Text(currentVideoPresetSummary())
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Image(systemName: isVideoPresetSectionExpanded ? "chevron.up" : "chevron.down")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if isVideoPresetSectionExpanded {
                    ForEach(LiveStreamConfig.Video.presets, id: \.id) { preset in
                        UIKitActionButton(title: "\(preset.title)  \(preset.width)x\(preset.height) @\(preset.fps)fps  \(preset.bitrate / 1000)kbps",
                                          titleColor: currentVideoPresetID == preset.id ? .white : .label,
                                          backgroundColor: currentVideoPresetID == preset.id ? UIColor.systemGreen.withAlphaComponent(0.92) : UIColor.systemGray5,
                                          accessibilityIdentifier: UIId.videoPresetButton(preset.id),
                                          labelAccessibilityIdentifier: UIId.videoPresetButtonLabel(preset.id),
                                          action: {
                                              applyVideoPreset(preset)
                                          })
                            .frame(maxWidth: .infinity)
                            .frame(height: 38)
                    }

                    if !videoPresetHint.isEmpty {
                        Text(videoPresetHint)
                            .font(.footnote)
                            .foregroundColor(.orange)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Text("当前档位: \(currentVideoPresetSummary())")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(Color.gray.opacity(0.08))
            .cornerRadius(10)

            VStack(alignment: .leading, spacing: 8) {
                Text("RTMP URL 设置")
                    .font(.headline)

                UIKitTextField(text: $rtmpURLInput,
                               isEditing: $isEditingRTMPURL,
                               placeholder: "rtmp://...",
                               keyboardType: .URL,
                               accessibilityIdentifier: UIId.rtmpURLTextField,
                               onTextChanged: {
                                   hasUnsavedRTMPURLInput = true
                               },
                               onSubmit: {
                                   saveRTMPURL()
                               })
                    .frame(maxWidth: .infinity)
                    .frame(height: 38)
                    .padding(.horizontal, 10)
                    .background(Color.gray.opacity(0.12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.gray.opacity(0.35), lineWidth: 1)
                    )
                    .cornerRadius(8)

                HStack(spacing: 10) {
                    UIKitActionButton(title: "保存",
                                      titleColor: .white,
                                      backgroundColor: UIColor.systemBlue.withAlphaComponent(0.9),
                                      accessibilityIdentifier: UIId.rtmpSaveButton,
                                      labelAccessibilityIdentifier: UIId.rtmpSaveButtonLabel,
                                      action: saveRTMPURL)
                        .frame(width: 72, height: 36)

                    UIKitActionButton(title: "恢复默认",
                                      titleColor: .label,
                                      backgroundColor: UIColor.systemGray5,
                                      accessibilityIdentifier: UIId.rtmpResetButton,
                                      labelAccessibilityIdentifier: UIId.rtmpResetButtonLabel,
                                      action: resetRTMPURLToDefault)
                        .frame(width: 96, height: 36)

                    Spacer()
                }

                if !rtmpConfigHint.isEmpty {
                    Text(rtmpConfigHint)
                        .font(.footnote)
                        .foregroundColor(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Text("当前生效: \(currentResolvedRTMPURL())")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(Color.gray.opacity(0.08))
            .cornerRadius(10)

            BroadcastPickerView(preferredExtensionBundleID: extensionBundleID,
                                isBroadcasting: isBroadcasting,
                                startTrigger: broadcastStartTrigger)
                .frame(width: 220, height: 56)
                .shadow(radius: 2)

            if !lastError.isEmpty {
                Text(lastError)
                    .font(.footnote)
                    .foregroundColor(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            

            if LiveStreamConfig.App.enableDiagnosticsDisplay {
                ScrollView {
                    Text(diagnosticText)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .ifAvailableTextSelection()
                }
                    .font(.system(size: 12, design: .monospaced))
                    .ifAvailableHiddenScrollContentBackground()
                    .background(Color.orange.opacity(0.12))
                    .frame(minHeight: 180, maxHeight: 220)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.orange.opacity(0.35), lineWidth: 1)
                    )
                    .cornerRadius(8)
            }

            if LiveStreamConfig.App.enableLogDisplay {
                
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(logs, id: \.self) { log in
                            Text(log)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.green)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding()
                .background(Color.black.opacity(0.8))
                .cornerRadius(8)
                .frame(maxHeight: 300)
            }

//            Text("如果点击没反应：请确认已安装并启用扩展；或重启 App/手机再试")
//                .font(.footnote)
//                .foregroundColor(.secondary)
        }
        .padding()
        .onAppear {
            loadRTMPURLFromDefaultsIfNeeded()
            refreshVideoPresetState()
            refreshStatus()
        }
        .onReceive(Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()) { _ in
            refreshStatus()
        }
        .onReceive(diagnosticNotifier.$tick) { _ in
            refreshStatus()
        }
    }

    private func refreshStatus() {
        let defaults = LiveStreamConfig.AppGroup.defaults(refresh: true)
        isBroadcasting = defaults?.bool(forKey: "recording.isRunning") ?? false
        lastFilePath = defaults?.string(forKey: "recording.lastFilePath") ?? ""
        lastError = defaults?.string(forKey: "recording.lastError") ?? ""
        exportedPath = defaults?.string(forKey: "recording.exportedPath") ?? ""
        // Avoid overwriting user input while editing.
        if !isEditingRTMPURL && !hasUnsavedRTMPURLInput {
            loadRTMPURLFromDefaultsIfNeeded()
        }
        consumeDeepLinkStartCommandIfNeeded(defaults: defaults)
        refreshVideoPresetState()
        if LiveStreamConfig.App.enableLogDisplay {
            logs = SharedLogger.readLogs().reversed()
        } else {
            logs = []
        }
        diagnosticText = buildDiagnosticText(defaults: defaults)
        logDiagnosticIfNeeded(diagnosticText)

        // 主 App 在这里负责导出：从 AppGroup 复制到本 App Documents
        let needsExport = defaults?.bool(forKey: "recording.needsExport") ?? false
        if !isBroadcasting, needsExport {
            exportFromAppGroupToDocumentsIfNeeded(defaults: defaults)
        } else if isBroadcasting {
            exportingHint = ""
        }
    }

    private func loadRTMPURLFromDefaultsIfNeeded() {
        let defaults = LiveStreamConfig.AppGroup.defaults(refresh: true)
        let overrideURL = defaults?.string(forKey: LiveStreamConfig.RTMP.userDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // Only refresh the field when not editing; keep user's manual edits otherwise.
        if !isEditingRTMPURL && !hasUnsavedRTMPURLInput {
            rtmpURLInput = overrideURL
        }
    }

    private func currentResolvedRTMPURL() -> String {
        // resolvedURL reads the current AppGroup defaults; keep it as the single source of truth.
        LiveStreamConfig.RTMP.resolvedURL
    }

    private func saveRTMPURL() {
        rtmpConfigHint = ""
        let trimmed = rtmpURLInput.trimmingCharacters(in: .whitespacesAndNewlines)

        if !isValidRTMPURL(trimmed) {
            rtmpConfigHint = "URL 非法：当前推流实现仅支持 rtmp://，且需要是可解析的 URL。"
            return
        }

        let defaultsList = LiveStreamConfig.AppGroup.availableDefaultsByGroupID(refresh: true)
        guard !defaultsList.isEmpty else {
            rtmpConfigHint = "保存失败：未找到可用的 App Group。"
            return
        }
        let targetGroups = defaultsList.map(\.0).joined(separator: ", ")
        if trimmed.isEmpty {
            for (_, defaults) in defaultsList {
                defaults.removeObject(forKey: LiveStreamConfig.RTMP.userDefaultsKey)
                defaults.synchronize()
            }
            rtmpConfigHint = "已清空覆盖值，将使用默认 URL（下次启动推流生效）。目标组: \(targetGroups)"
        } else {
            for (groupID, defaults) in defaultsList {
                defaults.set(trimmed, forKey: LiveStreamConfig.RTMP.userDefaultsKey)
                defaults.set(groupID, forKey: LiveStreamConfig.AppGroup.runtimeSelectedGroupKey)
                defaults.set(Date().timeIntervalSince1970, forKey: LiveStreamConfig.AppGroup.runtimeSelectedUpdatedAtKey)
                defaults.synchronize()
            }
            rtmpConfigHint = "已保存 RTMP URL（下次启动推流生效）。目标组: \(targetGroups)"
        }
        rtmpURLInput = trimmed
        hasUnsavedRTMPURLInput = false

        if isBroadcasting {
            rtmpConfigHint += " 当前正在推流，需先停止并重新开始才能切到新地址。"
        }
    }

    private func resetRTMPURLToDefault() {
        rtmpURLInput = ""
        hasUnsavedRTMPURLInput = false
        saveRTMPURL()
    }

    private func refreshVideoPresetState() {
        currentVideoPresetID = LiveStreamConfig.Video.currentPreset.id
    }

    private func applyVideoPreset(_ preset: LiveStreamConfig.Video.Preset) {
        LiveStreamConfig.Video.applyPreset(preset)
        currentVideoPresetID = preset.id
        videoPresetHint = "已切换到 \(preset.title)：\(preset.width)x\(preset.height) @\(preset.fps)fps / \(preset.bitrate / 1000)kbps。"
        if isBroadcasting {
            videoPresetHint += " 当前正在推流，需先停止并重新开始才能切到新档位。"
        }
    }

    private func currentVideoPresetSummary() -> String {
        let preset = LiveStreamConfig.Video.currentPreset
        return "\(preset.title) \(preset.width)x\(preset.height) @\(preset.fps)fps \(preset.bitrate / 1000)kbps"
    }

    private func isValidRTMPURL(_ raw: String) -> Bool {
        if raw.isEmpty { return true }
        return LiveStreamConfig.RTMP.isValidOverrideURL(raw)
    }

    private func consumeDeepLinkStartCommandIfNeeded(defaults: UserDefaults?) {
        guard let defaults else { return }
        guard defaults.bool(forKey: LiveStreamConfig.RTMP.deepLinkStartCommandKey) else { return }

        defaults.set(false, forKey: LiveStreamConfig.RTMP.deepLinkStartCommandKey)
        defaults.synchronize()

        let savedURL = defaults.string(forKey: LiveStreamConfig.RTMP.userDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !savedURL.isEmpty {
            rtmpURLInput = savedURL
            hasUnsavedRTMPURLInput = false
        }

        guard !isBroadcasting else {
            rtmpConfigHint = "已收到 deeplink 并保存 RTMP URL；当前正在录屏，未自动触发新的开始动作。"
            return
        }

        rtmpConfigHint = "已收到 deeplink 并保存 RTMP URL，正在尝试自动打开系统录屏面板。"
        broadcastStartTrigger &+= 1
    }

    private func exportFromAppGroupToDocumentsIfNeeded(defaults: UserDefaults?) {
        guard let defaults = defaults else { return }
        guard let srcPath = defaults.string(forKey: "recording.lastFilePath"), !srcPath.isEmpty else {
            return
        }

        let srcURL = URL(fileURLWithPath: srcPath)
        let docsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let destURL = docsDir.appendingPathComponent(srcURL.lastPathComponent)

        exportingHint = "正在导出到 Documents…"

        DispatchQueue.global(qos: .utility).async {
            do {
                if FileManager.default.fileExists(atPath: destURL.path) {
                    try FileManager.default.removeItem(at: destURL)
                }
                try FileManager.default.copyItem(at: srcURL, to: destURL)
                defaults.set(destURL.path, forKey: "recording.exportedPath")
                defaults.set(false, forKey: "recording.needsExport")
                DispatchQueue.main.async {
                    self.exportingHint = "导出完成，可在 Download Container 的 AppData/Documents 下找到。"
                }
            } catch {
                defaults.set("导出失败：\(error.localizedDescription)", forKey: "recording.lastError")
                DispatchQueue.main.async {
                    self.exportingHint = ""
                }
            }
        }
    }

    private func logDiagnosticIfNeeded(_ text: String) {
        guard LiveStreamConfig.App.enableLogRecording else { return }
        guard text != lastLoggedDiagnosticText else { return }
        lastLoggedDiagnosticText = text
        let singleLine = text.replacingOccurrences(of: "\n", with: " | ")
        if LiveStreamConfig.App.enableRuntimeLogging {
            NSLog("[LiveDiag] %@", singleLine)
        }
    }

    private func buildDiagnosticText(defaults: UserDefaults?) -> String {
        let pendingTags = defaults?.integer(forKey: "diag.rtmp.pendingTags") ?? 0
        let appGroupID = LiveStreamConfig.AppGroup.currentID(refresh: true)
        let rtmpHost = defaults?.string(forKey: "diag.rtmp.host") ?? "-"
        let rtmpApp = defaults?.string(forKey: "diag.rtmp.app") ?? "-"
        let rtmpStream = defaults?.string(forKey: "diag.rtmp.stream") ?? "-"
        let rtmpOpenState = defaults?.string(forKey: "diag.rtmp.openState") ?? "-"
        let droppedVideoTags = defaults?.integer(forKey: "diag.rtmp.droppedVideoTags") ?? 0
        let reconnectAttempt = defaults?.integer(forKey: "diag.rtmp.reconnectAttempt") ?? 0
        let isConnected = defaults?.bool(forKey: "diag.rtmp.isConnected") ?? false
        let sentPackets = defaults?.integer(forKey: "diag.rtmp.sentPackets") ?? 0
        let videoFramesPerSecond = defaults?.integer(forKey: "diag.rtmp.videoFramesPerSecond") ?? 0
        let audioTagsPerSecond = defaults?.integer(forKey: "diag.rtmp.audioTagsPerSecond") ?? 0
        let estimatedTagsPerSecond = max(1, videoFramesPerSecond + audioTagsPerSecond)
        let estimatedQueueDelayMs = Int((Double(pendingTags) / Double(estimatedTagsPerSecond) * 1000.0).rounded())

        let targetFps = defaults?.integer(forKey: "diag.h264.targetFps") ?? Int(LiveStreamConfig.Video.fps)
        let lastGapMs = defaults?.double(forKey: "diag.h264.lastGapMs") ?? 0
        let droppedDenseFrames = defaults?.integer(forKey: "diag.h264.droppedDenseFrames") ?? 0
        let resumeEvents = defaults?.integer(forKey: "diag.h264.resumeEvents") ?? 0
        let severeLowVideoOutput = targetFps > 0 && videoFramesPerSecond <= max(1, targetFps / 3)
        let moderateNetworkPressure = pendingTags >= 8
        let strongNetworkPressure = pendingTags >= 24 || droppedVideoTags > 0 || reconnectAttempt > 0

        let networkPressure: String
        if strongNetworkPressure {
            networkPressure = "高"
        } else if pendingTags >= 12 {
            networkPressure = "中"
        } else if pendingTags >= 6 {
            networkPressure = "低"
        } else {
            networkPressure = "很低"
        }

        let diagnosis: String
        let reason: String
        if severeLowVideoOutput && !strongNetworkPressure {
            diagnosis = "更像本地处理瓶颈"
            reason = "最近完整1s视频输出明显低于目标帧率，且没有出现明显弱网丢帧/重连；当前队列积压更像结果，不像根因。"
        } else if strongNetworkPressure {
            diagnosis = "更像网络/带宽瓶颈"
            reason = "发送队列堆积、弱网丢帧或发生重连，说明编码产出快于上行发送能力。"
        } else if (targetFps > 0 && videoFramesPerSecond > 0 && videoFramesPerSecond < max(1, targetFps * 2 / 3)) || lastGapMs >= 120 || resumeEvents > 0 || (moderateNetworkPressure && severeLowVideoOutput) {
            diagnosis = "更像本地处理瓶颈"
            reason = "视频实际输出偏低或采集 gap 偏大，通常是采集/缩放/编码链路跟不上。"
        } else if isBroadcasting && sentPackets > 0 {
            diagnosis = "暂未见明显瓶颈"
            reason = "当前网络队列平稳，视频节奏也基本跟上目标帧率。"
        } else {
            diagnosis = "等待更多样本"
            reason = "刚开始推流或尚未累计足够统计，先观察 3~5 秒。"
        }

        return "推流判断\n" +
        "- 结论: \(diagnosis)\n" +
        "- 依据: \(reason)\n" +
        "- AppGroup: \(appGroupID)\n" +
        "- RTMP目标: \(rtmpHost)/\(rtmpApp)/\(rtmpStream)\n" +
        "- 建连阶段: \(rtmpOpenState)\n" +
        "- 连接状态: \(isConnected ? "已连接" : "连接中/未连接")\n" +
        "- 发送累计: \(sentPackets) 包\n" +
        "- 网络压力: \(networkPressure)\n" +
        "- 队列积压: \(pendingTags) tags\n" +
        "- 估算排队时延: \(estimatedQueueDelayMs) ms\n" +
        "- 弱网丢视频: \(droppedVideoTags)\n" +
        "- 重连次数: \(reconnectAttempt)\n" +
        "- 最近完整1s视频输出: \(videoFramesPerSecond)/\(targetFps) fps\n" +
        "- 最近完整1s音频包: \(audioTagsPerSecond)\n" +
        "- 最近视频 gap: \(Int(lastGapMs.rounded())) ms\n" +
        "- 采集侧丢帧: \(droppedDenseFrames)\n" +
        "- 恢复关键帧次数: \(resumeEvents)"
    }
}

/// A SwiftUI wrapper around UIKit's UITextField, so automation can reliably find it in the UI tree.
private struct UIKitTextField: UIViewRepresentable {
    @Binding var text: String
    @Binding var isEditing: Bool
    let placeholder: String
    let keyboardType: UIKeyboardType
    let accessibilityIdentifier: String
    let onTextChanged: () -> Void
    let onSubmit: () -> Void

    func makeUIView(context: Context) -> UITextField {
        let tf = UITextField(frame: .zero)
        tf.borderStyle = .none
        tf.clearButtonMode = .whileEditing
        tf.autocapitalizationType = .none
        tf.autocorrectionType = .no
        tf.spellCheckingType = .no
        tf.keyboardType = keyboardType
        tf.returnKeyType = .done
        tf.placeholder = placeholder
        tf.text = text
        tf.delegate = context.coordinator
        tf.accessibilityIdentifier = accessibilityIdentifier
        tf.setContentHuggingPriority(.defaultLow, for: .horizontal)
        tf.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        tf.addTarget(context.coordinator, action: #selector(Coordinator.onChanged(_:)), for: .editingChanged)
        return tf
    }

    func updateUIView(_ uiView: UITextField, context: Context) {
        // Keep UIKit -> SwiftUI and SwiftUI -> UIKit in sync.
        if uiView.text != text {
            uiView.text = text
        }
        uiView.placeholder = placeholder
        uiView.keyboardType = keyboardType
        uiView.accessibilityIdentifier = accessibilityIdentifier
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, isEditing: $isEditing, onTextChanged: onTextChanged, onSubmit: onSubmit)
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        private let text: Binding<String>
        private let isEditing: Binding<Bool>
        private let onTextChanged: () -> Void
        private let onSubmit: () -> Void

        init(text: Binding<String>, isEditing: Binding<Bool>, onTextChanged: @escaping () -> Void, onSubmit: @escaping () -> Void) {
            self.text = text
            self.isEditing = isEditing
            self.onTextChanged = onTextChanged
            self.onSubmit = onSubmit
        }

        @objc func onChanged(_ textField: UITextField) {
            text.wrappedValue = textField.text ?? ""
            onTextChanged()
        }

        func textFieldDidBeginEditing(_ textField: UITextField) {
            isEditing.wrappedValue = true
        }

        func textFieldDidEndEditing(_ textField: UITextField) {
            isEditing.wrappedValue = false
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            text.wrappedValue = textField.text ?? ""
            onSubmit()
            textField.resignFirstResponder()
            return true
        }
    }
}

/// A UIKit-backed button so automation can detect a native UIButton with an inner UILabel.
private struct UIKitActionButton: UIViewRepresentable {
    let title: String
    let titleColor: UIColor
    let backgroundColor: UIColor
    let accessibilityIdentifier: String
    let labelAccessibilityIdentifier: String
    let action: () -> Void

    func makeUIView(context: Context) -> UILabelWrappedButton {
        let button = UILabelWrappedButton()
        button.accessibilityIdentifier = accessibilityIdentifier
        button.onTap = action
        button.addTarget(context.coordinator, action: #selector(Coordinator.handleTap), for: .touchUpInside)
        update(button: button)
        return button
    }

    func updateUIView(_ uiView: UILabelWrappedButton, context: Context) {
        uiView.onTap = action
        update(button: uiView)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    private func update(button: UILabelWrappedButton) {
        button.backgroundColor = backgroundColor
        button.layer.cornerRadius = 6
        button.clipsToBounds = true
        button.titleLabelView.text = title
        button.titleLabelView.textColor = titleColor
        button.titleLabelView.accessibilityIdentifier = labelAccessibilityIdentifier
        button.accessibilityLabel = title
    }

    final class Coordinator: NSObject {
        @objc func handleTap(_ sender: UILabelWrappedButton) {
            sender.onTap?()
        }
    }
}

private final class UILabelWrappedButton: UIButton {
    let titleLabelView = UILabel()
    var onTap: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    private func setup() {
        titleLabelView.translatesAutoresizingMaskIntoConstraints = false
        titleLabelView.font = UIFont.systemFont(ofSize: 13, weight: .semibold)
        titleLabelView.textAlignment = .center
        titleLabelView.numberOfLines = 1
        titleLabelView.isUserInteractionEnabled = false
        addSubview(titleLabelView)

        NSLayoutConstraint.activate([
            titleLabelView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            titleLabelView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            titleLabelView.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            titleLabelView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6)
        ])
    }
}

private final class DarwinNotificationObserver: ObservableObject {
    @Published var tick: Int = 0

    private let names: [String]

    init(names: [String]) {
        self.names = names
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        for name in names {
            CFNotificationCenterAddObserver(
                center,
                Unmanaged.passUnretained(self).toOpaque(),
                DarwinNotificationObserver.callback,
                name as CFString,
                nil,
                .deliverImmediately
            )
        }
    }

    deinit {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        for name in names {
            CFNotificationCenterRemoveObserver(
                center,
                Unmanaged.passUnretained(self).toOpaque(),
                CFNotificationName(name as CFString),
                nil
            )
        }
    }

    private static let callback: CFNotificationCallback = { _, observer, _, _, _ in
        guard let observer else { return }
        let instance = Unmanaged<DarwinNotificationObserver>.fromOpaque(observer).takeUnretainedValue()
        DispatchQueue.main.async {
            instance.tick &+= 1
        }
    }
}

private extension View {
    @ViewBuilder
    func ifAvailableHiddenScrollContentBackground() -> some View {
        if #available(iOS 16.0, *) {
            self.scrollContentBackground(.hidden)
        } else {
            self
        }
    }

    @ViewBuilder
    func ifAvailableTextSelection() -> some View {
        if #available(iOS 15.0, *) {
            self.textSelection(.enabled)
        } else {
            self
        }
    }
}
