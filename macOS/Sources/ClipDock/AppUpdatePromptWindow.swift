import AppKit

@MainActor
final class AppUpdatePromptWindowPresenter: AppUpdatePromptPresenting {
    private var activeControllers: [AppUpdatePromptWindowController] = []

    func presentUpdatePrompt(
        release: AppUpdateRelease,
        currentVersion: String,
        onAction: @escaping (AppUpdatePromptAction) -> Void
    ) {
        let controller = AppUpdatePromptWindowController(
            release: release,
            currentVersion: currentVersion
        ) { [weak self] controller, action in
            // 开始安装后窗口要留着显示进度，只有「稍后 / 跳过」才关闭。
            if action != .download {
                self?.activeControllers.removeAll { $0 === controller }
            }
            onAction(action)
        }
        activeControllers.append(controller)
        controller.present()
    }

    func updateInstallState(_ state: AppUpdateInstallState) {
        for controller in activeControllers {
            controller.updateInstallState(state)
        }
    }

    var hasActivePrompt: Bool {
        !activeControllers.isEmpty
    }

    func dismissAll() {
        activeControllers.removeAll()
    }
}

@MainActor
private final class AppUpdatePromptWindowController: NSWindowController, NSWindowDelegate {
    private enum Layout {
        static let initialSize = NSSize(width: 760, height: 500)
        static let minimumSize = NSSize(width: 680, height: 430)
    }

    private var didComplete = false
    private weak var contentView: AppUpdatePromptContentView?
    private let onCompletion: (AppUpdatePromptWindowController, AppUpdatePromptAction) -> Void

    func updateInstallState(_ state: AppUpdateInstallState) {
        contentView?.updateInstallState(state)
    }

    init(
        release: AppUpdateRelease,
        currentVersion: String,
        onCompletion: @escaping (AppUpdatePromptWindowController, AppUpdatePromptAction) -> Void
    ) {
        self.onCompletion = onCompletion
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Layout.initialSize),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.level = .normal
        window.contentMinSize = Layout.minimumSize

        super.init(window: window)
        window.delegate = self
        let contentView = AppUpdatePromptContentView(
            release: release,
            currentVersion: currentVersion,
            onAction: { [weak self] action in
                self?.complete(action)
            }
        )
        self.contentView = contentView
        window.contentView = contentView
        window.initialFirstResponder = window.contentView
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func present() {
        guard let window else {
            complete(.skipForNow)
            return
        }
        didComplete = false

        window.level = .normal
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        complete(.skipForNow)
        return false
    }

    private func complete(_ action: AppUpdatePromptAction) {
        guard !didComplete else { return }
        didComplete = true
        window?.orderOut(nil)
        onCompletion(self, action)
    }
}

@MainActor
final class AppUpdatePromptContentView: NSVisualEffectView {
    private enum Layout {
        static let contentInsets = NSEdgeInsets(top: 72, left: 42, bottom: 32, right: 42)
        static let iconSize: CGFloat = 72
        static let notesMinHeight: CGFloat = 188
        static let buttonWidth: CGFloat = 136
        static let primaryButtonWidth: CGFloat = 148
        static let buttonHeight: CGFloat = 34
    }

    private let onAction: (AppUpdatePromptAction) -> Void
    private var installButton: NSButton?
    private var remindButton: NSButton?
    private var skipButton: NSButton?
    private var progressIndicator: NSProgressIndicator?
    private var progressLabel: NSTextField?
    private var installState: AppUpdateInstallState = .idle

    init(
        release: AppUpdateRelease,
        currentVersion: String,
        onAction: @escaping (AppUpdatePromptAction) -> Void
    ) {
        self.onAction = onAction
        super.init(frame: .zero)

        material = .windowBackground
        blendingMode = .behindWindow
        state = .active
        setupContent(release: release, currentVersion: currentVersion)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override func cancelOperation(_ sender: Any?) {
        onAction(.skipForNow)
    }

    private func setupContent(release: AppUpdateRelease, currentVersion: String) {
        let rootStack = NSStackView()
        rootStack.orientation = .vertical
        rootStack.alignment = .leading
        rootStack.spacing = 20
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rootStack)

        let header = makeHeader(release: release, currentVersion: currentVersion)
        let releaseNotes = makeReleaseNotesView(for: release)
        let progress = makeProgressView()
        let footer = makeFooter()
        rootStack.addArrangedSubview(header)
        rootStack.addArrangedSubview(releaseNotes)
        rootStack.addArrangedSubview(progress)
        rootStack.addArrangedSubview(footer)

        NSLayoutConstraint.activate([
            rootStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Layout.contentInsets.left),
            rootStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Layout.contentInsets.right),
            rootStack.topAnchor.constraint(equalTo: topAnchor, constant: Layout.contentInsets.top),
            rootStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Layout.contentInsets.bottom),
            header.widthAnchor.constraint(equalTo: rootStack.widthAnchor),
            releaseNotes.widthAnchor.constraint(equalTo: rootStack.widthAnchor),
            progress.widthAnchor.constraint(equalTo: rootStack.widthAnchor),
            footer.widthAnchor.constraint(equalTo: rootStack.widthAnchor)
        ])
    }

    /// 安装进度行：默认隐藏，点「安装更新」后才出现。
    private func makeProgressView() -> NSView {
        let container = NSStackView()
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 6
        container.isHidden = true

        let indicator = NSProgressIndicator()
        indicator.style = .bar
        indicator.isIndeterminate = false
        indicator.minValue = 0
        indicator.maxValue = 1
        indicator.translatesAutoresizingMaskIntoConstraints = false
        indicator.heightAnchor.constraint(equalToConstant: 8).isActive = true

        let label = NSTextField(labelWithString: "")
        label.font = .systemFont(ofSize: 12.5)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 2

        container.addArrangedSubview(label)
        container.addArrangedSubview(indicator)
        indicator.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true

        progressIndicator = indicator
        progressLabel = label
        return container
    }

    func updateInstallState(_ state: AppUpdateInstallState) {
        installState = state
        guard let installButton, let remindButton, let skipButton else { return }

        switch state {
        case .idle:
            progressIndicator?.superview?.isHidden = true
            installButton.isEnabled = true
            installButton.title = AppLocalization.text("update.prompt.install", defaultValue: "安装更新")
            remindButton.isEnabled = true
            skipButton.isEnabled = true

        case .downloading(let progress):
            progressIndicator?.superview?.isHidden = false
            installButton.isEnabled = false
            installButton.title = AppLocalization.text("update.install.inProgress", defaultValue: "正在安装…")
            remindButton.isEnabled = false
            skipButton.isEnabled = false
            progressLabel?.stringValue = progress?.statusText
                ?? AppLocalization.text("update.install.downloading", defaultValue: "正在下载更新…")
            progressLabel?.textColor = .secondaryLabelColor
            if let fraction = progress?.fraction {
                progressIndicator?.isIndeterminate = false
                progressIndicator?.doubleValue = fraction
            } else {
                progressIndicator?.isIndeterminate = true
                progressIndicator?.startAnimation(nil)
            }

        case .installed:
            progressIndicator?.superview?.isHidden = false
            installButton.isEnabled = false
            installButton.title = AppLocalization.text("update.install.done", defaultValue: "正在重启…")
            remindButton.isEnabled = false
            skipButton.isEnabled = false
            progressLabel?.stringValue = AppLocalization.text(
                "update.install.completed",
                defaultValue: "安装完成，正在重新启动 ClipDock…"
            )
            progressLabel?.textColor = .secondaryLabelColor
            progressIndicator?.isIndeterminate = false
            progressIndicator?.doubleValue = 1

        case .failed(let message):
            progressIndicator?.superview?.isHidden = false
            installButton.isEnabled = true
            installButton.title = AppLocalization.text("update.install.retry", defaultValue: "重试")
            remindButton.isEnabled = true
            skipButton.isEnabled = true
            progressLabel?.stringValue = message
            progressLabel?.textColor = .systemRed
            progressIndicator?.isIndeterminate = false
            progressIndicator?.doubleValue = 0
        }
    }

    private func makeHeader(release: AppUpdateRelease, currentVersion: String) -> NSView {
        let header = NSStackView()
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 18
        header.translatesAutoresizingMaskIntoConstraints = false

        let iconView = NSImageView()
        iconView.image = AppIconDisplayImageProvider.image(accessibilityDescription: "ClipDock")
            ?? NSApp.applicationIconImage
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            iconView.widthAnchor.constraint(equalToConstant: Layout.iconSize),
            iconView.heightAnchor.constraint(equalToConstant: Layout.iconSize)
        ])

        let textStack = NSStackView()
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 8

        let title = NSTextField(labelWithString: AppLocalization.text(
            "update.prompt.title",
            defaultValue: "新版本的 ClipDock 已经发布"
        ))
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        title.textColor = .labelColor
        title.lineBreakMode = .byTruncatingTail
        title.maximumNumberOfLines = 1

        let message = NSTextField(labelWithString: AppLocalization.format(
            "update.prompt.message",
            defaultValue: "ClipDock %@ 可供下载，您现在的版本是 %@。要现在下载吗？",
            release.displayVersion,
            currentVersion
        ))
        message.font = .systemFont(ofSize: 14.5, weight: .regular)
        message.textColor = .secondaryLabelColor
        message.lineBreakMode = .byWordWrapping
        message.maximumNumberOfLines = 2

        textStack.addArrangedSubview(title)
        textStack.addArrangedSubview(message)

        header.addArrangedSubview(iconView)
        header.addArrangedSubview(textStack)
        header.setHuggingPriority(.defaultLow, for: .horizontal)
        textStack.setHuggingPriority(.defaultLow, for: .horizontal)

        return header
    }

    private func makeReleaseNotesView(for release: AppUpdateRelease) -> NSView {
        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .controlBackgroundColor
        scrollView.wantsLayer = true
        scrollView.layer?.cornerRadius = 9
        scrollView.layer?.borderWidth = 1
        scrollView.layer?.borderColor = NSColor.separatorColor.cgColor

        let textView = NSTextView()
        textView.drawsBackground = false
        textView.isEditable = false
        textView.isSelectable = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 16, height: 16)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textStorage?.setAttributedString(
            AppUpdatePromptReleaseNotesFormatter.attributedString(for: release, appName: "ClipDock")
        )

        scrollView.documentView = textView
        NSLayoutConstraint.activate([
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: Layout.notesMinHeight)
        ])
        return scrollView
    }

    private func makeFooter() -> NSView {
        let footer = NSStackView()
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 16
        footer.translatesAutoresizingMaskIntoConstraints = false

        let skipButton = makeButton(
            title: AppLocalization.text("update.prompt.skipVersion", defaultValue: "跳过这个版本"),
            width: Layout.buttonWidth,
            action: #selector(skipVersion)
        )
        let remindButton = makeButton(
            title: AppLocalization.text("update.prompt.remindLater", defaultValue: "稍后提醒我"),
            width: Layout.buttonWidth,
            action: #selector(remindLater)
        )
        remindButton.keyEquivalent = "\u{1b}"
        let installButton = makeButton(
            title: AppLocalization.text("update.prompt.install", defaultValue: "安装更新"),
            width: Layout.primaryButtonWidth,
            action: #selector(installUpdate),
            isPrimary: true
        )
        installButton.keyEquivalent = "\r"

        self.skipButton = skipButton
        self.remindButton = remindButton
        self.installButton = installButton

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false

        footer.addArrangedSubview(skipButton)
        footer.addArrangedSubview(spacer)
        footer.addArrangedSubview(remindButton)
        footer.addArrangedSubview(installButton)
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        footer.setHuggingPriority(.defaultLow, for: .horizontal)

        return footer
    }

    private func makeButton(
        title: String,
        width: CGFloat,
        action: Selector,
        isPrimary: Bool = false
    ) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.bezelStyle = .rounded
        button.controlSize = .large
        button.font = .systemFont(ofSize: 14, weight: isPrimary ? .semibold : .medium)
        if isPrimary {
            button.bezelColor = .controlAccentColor
            button.contentTintColor = .white
        }
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: width),
            button.heightAnchor.constraint(equalToConstant: Layout.buttonHeight)
        ])
        return button
    }

    @objc private func installUpdate() {
        // 安装进行中不重复触发；失败后按钮会变成「重试」。
        guard !installState.isBusy, !isInstalled else { return }
        onAction(.download)
    }

    @objc private func remindLater() {
        guard !installState.isBusy else { return }
        onAction(.skipForNow)
    }

    @objc private func skipVersion() {
        guard !installState.isBusy else { return }
        onAction(.skipVersion)
    }

    private var isInstalled: Bool {
        if case .installed = installState { return true }
        return false
    }
}

private enum AppUpdatePromptReleaseNotesFormatter {
    static func attributedString(for release: AppUpdateRelease, appName: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        append(
            "\(appName) \(release.displayVersion)",
            to: result,
            font: .systemFont(ofSize: 22, weight: .bold),
            color: .labelColor,
            paragraphSpacing: 18
        )

        let notes = release.releaseNotes?.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = notes?.isEmpty == false
            ? notes ?? ""
            : AppLocalization.text(
                "update.prompt.releaseNotesFallback",
                defaultValue: "此版本包含改进和问题修复。"
            )

        for line in body.components(separatedBy: .newlines) {
            appendMarkdownLine(line, to: result)
        }
        return result
    }

    private static func appendMarkdownLine(_ line: String, to result: NSMutableAttributedString) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            result.append(NSAttributedString(string: "\n"))
            return
        }

        if trimmed.hasPrefix("### ") {
            appendHeading(String(trimmed.dropFirst(4)), to: result)
        } else if trimmed.hasPrefix("## ") {
            appendHeading(String(trimmed.dropFirst(3)), to: result)
        } else if trimmed.hasPrefix("# ") {
            appendHeading(String(trimmed.dropFirst(2)), to: result)
        } else if let bullet = bulletText(from: trimmed) {
            appendBullet(bullet, to: result)
        } else {
            append(
                plainText(from: trimmed),
                to: result,
                font: .systemFont(ofSize: 14, weight: .regular),
                color: .labelColor,
                paragraphSpacing: 6,
                lineSpacing: 2
            )
        }
    }

    private static func appendHeading(_ text: String, to result: NSMutableAttributedString) {
        append(
            plainText(from: text),
            to: result,
            font: .systemFont(ofSize: 15, weight: .semibold),
            color: .labelColor,
            paragraphSpacing: 10,
            lineSpacing: 2
        )
    }

    private static func appendBullet(_ text: String, to result: NSMutableAttributedString) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.firstLineHeadIndent = 22
        paragraph.headIndent = 38
        paragraph.paragraphSpacing = 5
        paragraph.lineSpacing = 2
        result.append(NSAttributedString(
            string: "•  \(plainText(from: text))\n",
            attributes: [
                .font: NSFont.systemFont(ofSize: 14, weight: .regular),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraph
            ]
        ))
    }

    private static func append(
        _ text: String,
        to result: NSMutableAttributedString,
        font: NSFont,
        color: NSColor,
        paragraphSpacing: CGFloat,
        lineSpacing: CGFloat = 0
    ) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacing = paragraphSpacing
        paragraph.lineSpacing = lineSpacing
        result.append(NSAttributedString(
            string: "\(plainText(from: text))\n",
            attributes: [
                .font: font,
                .foregroundColor: color,
                .paragraphStyle: paragraph
            ]
        ))
    }

    private static func bulletText(from line: String) -> String? {
        for prefix in ["- ", "* "] where line.hasPrefix(prefix) {
            return String(line.dropFirst(prefix.count))
        }
        return nil
    }

    private static func plainText(from markdown: String) -> String {
        var text = replacingMarkdownLinks(in: markdown)
        for marker in ["**", "__", "`"] {
            text = text.replacingOccurrences(of: marker, with: "")
        }
        return text
    }

    private static func replacingMarkdownLinks(in value: String) -> String {
        let pattern = #"\[([^\]]+)\]\([^)]+\)"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return value
        }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return expression.stringByReplacingMatches(
            in: value,
            range: range,
            withTemplate: "$1"
        )
    }
}
