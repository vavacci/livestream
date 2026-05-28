import SwiftUI
import ReplayKit

/// iOS14 可用的系统广播选择器
struct BroadcastPickerView: UIViewRepresentable {
    let preferredExtensionBundleID: String
    let isBroadcasting: Bool
    let startTrigger: Int

    func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
        let picker = RPSystemBroadcastPickerView(frame: .zero)
        picker.preferredExtension = preferredExtensionBundleID
        picker.showsMicrophoneButton = true
        styleInnerButton(in: picker)
        DispatchQueue.main.async { [weak picker] in
            if let picker = picker { styleInnerButton(in: picker) }
        }
        return picker
    }

    func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {
        uiView.preferredExtension = preferredExtensionBundleID
        styleInnerButton(in: uiView)
        DispatchQueue.main.async { styleInnerButton(in: uiView) }
        guard startTrigger != context.coordinator.lastStartTrigger else { return }
        context.coordinator.lastStartTrigger = startTrigger
        guard startTrigger > 0, !isBroadcasting else { return }
        DispatchQueue.main.async { [weak uiView] in
            guard let uiView, let button = findFirstButton(in: uiView) else { return }
            button.sendActions(for: .touchUpInside)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        var lastStartTrigger: Int = 0
    }

    private func styleInnerButton(in picker: RPSystemBroadcastPickerView) {
        guard let button = findFirstButton(in: picker) else {
            picker.backgroundColor = UIColor.systemGray5
            picker.layer.cornerRadius = 10
            picker.clipsToBounds = true
            return
        }

        button.frame = picker.bounds
        button.autoresizingMask = [.flexibleWidth, .flexibleHeight]

        let title = isBroadcasting ? "停止录屏" : "开始录屏"
        let bgColor = isBroadcasting ? UIColor.systemRed : UIColor.systemBlue
        button.setTitle(title, for: .normal)
        button.setTitleColor(.white, for: .normal)
        button.backgroundColor = bgColor
        button.layer.cornerRadius = 10
        button.clipsToBounds = true
        button.titleLabel?.font = UIFont.boldSystemFont(ofSize: 17)
        button.accessibilityLabel = title
        picker.backgroundColor = .clear
    }

    private func findFirstButton(in view: UIView) -> UIButton? {
        if let b = view as? UIButton { return b }
        for sub in view.subviews {
            if let b = findFirstButton(in: sub) { return b }
        }
        return nil
    }
}
