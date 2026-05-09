import UIKit
import UniformTypeIdentifiers
import SmartTubeIOSCore
import os

private let shareLog = Logger(subsystem: "com.void.smarttube.app.shareextension", category: "Share")

// MARK: - ShareViewController
//
// Presents a compact sheet with an "Open in SmartTube" button. The button tap
// is user-initiated, which is required for `extensionContext?.open(_:)` to
// reliably launch the containing app from a Share Extension in modern iOS —
// programmatic (non-user-initiated) calls are not honoured when the host is a
// third-party app such as the YouTube app.
//
// The video ID is also written to the shared App Group UserDefaults as a
// fallback so `AppEntry.consumePendingVideoID()` can pick it up.

final class ShareViewController: UIViewController {

    private static let appGroup             = "group.com.void.smarttube"
    private static let pendingKey           = "pendingVideoID"
    private static let pendingWatchLaterKey = "pendingWatchLaterVideoID"
    private static let pendingQueueKey      = "pendingQueueVideoID"

    // Set after successful URL extraction; nil means extraction failed or pending.
    private var deeplink: URL?
    private var resolvedVideoID: String?

    // MARK: - UI

    private let spinner: UIActivityIndicatorView = {
        let v = UIActivityIndicatorView(style: .medium)
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }()

    private let openButton: UIButton = {
        var config = UIButton.Configuration.filled()
        config.title = "Open in SmartTube"
        config.cornerStyle = .large
        config.baseBackgroundColor = UIColor(red: 0.40, green: 0.20, blue: 0.80, alpha: 1)
        let b = UIButton(configuration: config)
        b.translatesAutoresizingMaskIntoConstraints = false
        return b
    }()

    private let watchLaterButton: UIButton = {
        var config = UIButton.Configuration.bordered()
        config.title = "Add to Watch Later"
        config.cornerStyle = .large
        config.baseForegroundColor = UIColor(red: 0.40, green: 0.20, blue: 0.80, alpha: 1)
        config.image = UIImage(
            systemName: "clock.badge.plus",
            withConfiguration: UIImage.SymbolConfiguration(scale: .small)
        )
        config.imagePadding = 6
        let b = UIButton(configuration: config)
        b.translatesAutoresizingMaskIntoConstraints = false
        return b
    }()

    private let addToQueueButton: UIButton = {
        var config = UIButton.Configuration.bordered()
        config.title = "Add to Queue"
        config.cornerStyle = .large
        config.baseForegroundColor = UIColor(red: 0.40, green: 0.20, blue: 0.80, alpha: 1)
        config.image = UIImage(
            systemName: "list.bullet.indent",
            withConfiguration: UIImage.SymbolConfiguration(scale: .small)
        )
        config.imagePadding = 6
        let b = UIButton(configuration: config)
        b.translatesAutoresizingMaskIntoConstraints = false
        return b
    }()

    private let buttonStack: UIStackView = {
        let sv = UIStackView()
        sv.axis = .vertical
        sv.spacing = 12
        sv.translatesAutoresizingMaskIntoConstraints = false
        sv.isHidden = true
        return sv
    }()

    private let statusLabel: UILabel = {
        let l = UILabel()
        l.text = "Looking for video\u{2026}"
        l.textColor = .secondaryLabel
        l.font = .systemFont(ofSize: 15)
        l.textAlignment = .center
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }()

    private let titleLabel: UILabel = {
        let l = UILabel()
        l.text = "SmartTube"
        l.font = .systemFont(ofSize: 15, weight: .semibold)
        l.textColor = .label
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }()

    private let closeButton: UIButton = {
        let sym = UIImage(
            systemName: "xmark.circle.fill",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 22, weight: .regular)
        )
        var cfg = UIButton.Configuration.plain()
        cfg.image = sym
        cfg.baseForegroundColor = .tertiaryLabel
        let b = UIButton(configuration: cfg)
        b.accessibilityLabel = "Close"
        b.translatesAutoresizingMaskIntoConstraints = false
        return b
    }()

    private let headerDivider: UIView = {
        let v = UIView()
        v.backgroundColor = .separator
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }()

    private let logDivider: UIView = {
        let v = UIView()
        v.backgroundColor = .separator
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }()

    private let logLabel: UILabel = {
        let l = UILabel()
        l.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        l.textColor = .tertiaryLabel
        l.numberOfLines = 0
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }()

    private var logLines: [String] = []

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        preferredContentSize = CGSize(width: view.bounds.width, height: 372)

        buttonStack.addArrangedSubview(openButton)
        buttonStack.addArrangedSubview(watchLaterButton)
        buttonStack.addArrangedSubview(addToQueueButton)

        view.addSubview(titleLabel)
        view.addSubview(closeButton)
        view.addSubview(headerDivider)
        view.addSubview(spinner)
        view.addSubview(statusLabel)
        view.addSubview(buttonStack)
        view.addSubview(logDivider)
        view.addSubview(logLabel)

        let dividerH = 1.0 / UIScreen.main.scale
        NSLayoutConstraint.activate([
            // Title bar
            titleLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 14),
            titleLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),

            closeButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            closeButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 44),
            closeButton.heightAnchor.constraint(equalToConstant: 44),

            // Header divider
            headerDivider.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 12),
            headerDivider.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            headerDivider.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            headerDivider.heightAnchor.constraint(equalToConstant: dividerH),

            // Spinner — centred in the first-button zone while resolving
            spinner.topAnchor.constraint(equalTo: headerDivider.bottomAnchor, constant: 52),
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),

            // Status label (shown during resolution)
            statusLabel.topAnchor.constraint(equalTo: spinner.bottomAnchor, constant: 8),
            statusLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            statusLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            statusLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),

            // Button stack (shown after resolution)
            buttonStack.topAnchor.constraint(equalTo: headerDivider.bottomAnchor, constant: 24),
            buttonStack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            buttonStack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            openButton.heightAnchor.constraint(equalToConstant: 50),
            watchLaterButton.heightAnchor.constraint(equalToConstant: 50),
            addToQueueButton.heightAnchor.constraint(equalToConstant: 50),

            // Log section divider
            logDivider.topAnchor.constraint(equalTo: headerDivider.bottomAnchor, constant: 220),
            logDivider.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            logDivider.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            logDivider.heightAnchor.constraint(equalToConstant: dividerH),

            // Log label
            logLabel.topAnchor.constraint(equalTo: logDivider.bottomAnchor, constant: 8),
            logLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            logLabel.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            logLabel.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -8),
        ])

        spinner.startAnimating()
        openButton.addTarget(self, action: #selector(openButtonTapped), for: .touchUpInside)
        watchLaterButton.addTarget(self, action: #selector(watchLaterButtonTapped), for: .touchUpInside)
        addToQueueButton.addTarget(self, action: #selector(addToQueueButtonTapped), for: .touchUpInside)
        closeButton.addTarget(self, action: #selector(closeButtonTapped), for: .touchUpInside)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        shareLog.notice("viewDidAppear — starting extraction")
        logEntry("Looking for video\u{2026}")
        Task { @MainActor in await extractAndPrepare() }
    }

    // MARK: - Close

    @objc private func closeButtonTapped() {
        shareLog.notice("closeButtonTapped")
        cancel()
    }

    // MARK: - Log

    private func logEntry(_ message: String) {
        logLines.append(message)
        if logLines.count > 6 { logLines.removeFirst() }
        logLabel.text = logLines.joined(separator: "\n")
    }

    // MARK: - Watch Later

    @objc private func watchLaterButtonTapped() {
        guard let videoID = resolvedVideoID else {
            logEntry("⚠️ no video ID — cannot queue")
            return
        }
        if let defaults = UserDefaults(suiteName: Self.appGroup) {
            defaults.set(videoID, forKey: Self.pendingWatchLaterKey)
            defaults.synchronize()
            logEntry("✅ Queued for Watch Later")
            watchLaterButton.isEnabled = false
            var cfg = watchLaterButton.configuration
            cfg?.title = "Added to Watch Later"
            watchLaterButton.configuration = cfg
        } else {
            logEntry("❌ Could not write to shared storage")
        }
    }

    // MARK: - Add to Queue

    @objc private func addToQueueButtonTapped() {
        guard let videoID = resolvedVideoID else {
            logEntry("⚠️ no video ID — cannot add to queue")
            return
        }
        if let defaults = UserDefaults(suiteName: Self.appGroup) {
            defaults.set(videoID, forKey: Self.pendingQueueKey)
            defaults.synchronize()
            logEntry("✅ Added to Queue")
            addToQueueButton.isEnabled = false
            var cfg = addToQueueButton.configuration
            cfg?.title = "Added to Queue"
            addToQueueButton.configuration = cfg
        } else {
            logEntry("❌ Could not write to shared storage")
        }
    }

    // MARK: - User action

    @objc private func openButtonTapped() {
        guard let deeplink else {
            shareLog.error("openButtonTapped — deeplink is nil")
            logEntry("⚠️ deeplink is nil — nothing to open")
            return
        }
        logEntry("Tap → \(deeplink.absoluteString)")
        shareLog.notice("openButtonTapped — \(deeplink.absoluteString, privacy: .public)")

        // Strategy 1: extensionContext?.open() — completion is called on main thread.
        if let ctx = extensionContext {
            logEntry("Trying extensionContext.open…")
            ctx.open(deeplink) { [weak self] success in
                if success {
                    self?.logEntry("✅ extensionContext.open succeeded")
                } else {
                    self?.logEntry("❌ extensionContext.open returned false")
                    guard let self else { return }
                    self.openViaResponderChain(deeplink)
                }
            }
            return
        }

        logEntry("No extensionContext — trying responder chain")
        openViaResponderChain(deeplink)
    }

    private func openViaResponderChain(_ deeplink: URL) {
        var responder: UIResponder? = self
        var depth = 0
        while let r = responder {
            depth += 1
            if let app = r as? UIApplication {
                logEntry("UIApplication at depth \(depth), opening…")
                shareLog.notice("dispatching via UIApplication responder chain")
                // Completion is called on main thread per Apple docs.
                app.open(deeplink, options: [:]) { [weak self] success in
                    if success {
                        self?.logEntry("✅ UIApplication.open succeeded")
                    } else {
                        self?.logEntry("❌ UIApplication.open returned false")
                    }
                    self?.extensionContext?.completeRequest(returningItems: nil)
                }
                return
            }
            responder = r.next
        }

        logEntry("❌ No UIApplication in chain (depth \(depth))")
        logEntry("App Group written — open SmartTube manually")
        shareLog.error("no UIApplication found after \(depth) hops — App Group fallback")
        extensionContext?.completeRequest(returningItems: nil)
    }

    // MARK: - Extraction

    @MainActor
    private func extractAndPrepare() async {
        guard let items = extensionContext?.inputItems as? [NSExtensionItem] else {
            shareLog.error("No inputItems — cancelling")
            cancel(); return
        }

        shareLog.notice("inputItems count: \(items.count, privacy: .public)")

        guard let (videoID, _) = await resolveVideoID(from: items) else {
            shareLog.error("No YouTube URL found")
            spinner.stopAnimating()
            spinner.isHidden = true
            statusLabel.text = "Cannot find a YouTube video URL."
            statusLabel.textColor = .secondaryLabel
            try? await Task.sleep(for: .seconds(2))
            cancel()
            return
        }

        shareLog.notice("videoID: \(videoID, privacy: .public)")
        resolvedVideoID = videoID

        // Write to App Group (reliable data-transfer fallback)
        if let defaults = UserDefaults(suiteName: Self.appGroup) {
            defaults.set(videoID, forKey: Self.pendingKey)
            defaults.synchronize()
            shareLog.notice("wrote to App Group")
        } else {
            shareLog.error("FAILED to open App Group \(Self.appGroup, privacy: .public)")
        }

        guard let link = URL(string: "smarttube://video/\(videoID)") else {
            shareLog.error("failed to build deeplink — cancelling")
            cancel(); return
        }

        deeplink = link

        // Show both action buttons — user tap required for extensionContext.open
        spinner.stopAnimating()
        spinner.isHidden = true
        statusLabel.isHidden = true
        buttonStack.isHidden = false
    }

    // MARK: - URL resolution

    /// Extracts all candidate URLs from the NSExtensionItem list, then runs each
    /// through `URLVideoResolver` (direct parse → redirect chain → scrape).
    /// Returns the first `(videoID, deeplink)` pair found, or `nil`.
    private func resolveVideoID(from items: [NSExtensionItem]) async -> (String, URL)? {
        let resolver = URLVideoResolver()
        for (i, item) in items.enumerated() {
            let attachments = item.attachments ?? []
            shareLog.notice("item[\(i, privacy: .public)] attachments: \(attachments.count, privacy: .public)")
            for (j, provider) in attachments.enumerated() {
                shareLog.notice("  provider[\(j, privacy: .public)] types: \(provider.registeredTypeIdentifiers.joined(separator: ", "), privacy: .public)")
                guard let url = await loadURL(from: provider, index: j) else { continue }
                logEntry("Checking: \(url.host ?? url.absoluteString)\u{2026}")
                let progress: @Sendable (String) -> Void = { [weak self] message in
                    Task { @MainActor [weak self] in self?.logEntry(message) }
                }
                if let id = await resolver.resolve(url: url, onProgress: progress) {
                    guard let link = URL(string: "smarttube://video/\(id)") else { continue }
                    return (id, link)
                }
            }
        }
        return nil
    }

    /// Tries `public.url` first, then `public.plain-text` as a fallback.
    private func loadURL(from provider: NSItemProvider, index j: Int) async -> URL? {
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            let loaded = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier)
            shareLog.notice("  provider[\(j, privacy: .public)] url loaded: \(String(describing: loaded), privacy: .public)")
            if let u = loaded as? URL { return u }
            if let s = loaded as? String { return URL(string: s) }
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            let loaded = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier)
            if let s = loaded as? String {
                let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
                shareLog.notice("  provider[\(j, privacy: .public)] text fallback: \(trimmed, privacy: .public)")
                return URL(string: trimmed)
            }
        }
        return nil
    }

    // MARK: - Cancel

    private func cancel() {
        shareLog.notice("cancel() called")
        extensionContext?.cancelRequest(
            withError: NSError(domain: "com.void.smarttube.share", code: 0, userInfo: nil)
        )
    }
}

