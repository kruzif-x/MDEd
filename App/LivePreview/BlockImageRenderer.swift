import Cocoa
import CryptoKit
import WebKit

/// Renders a table, a KaTeX math expression, or a Mermaid diagram to an `NSImage` in an *offscreen*
/// `WKWebView` — the piece that turns a block-level Markdown construct into the image
/// `LivePreviewController` embeds as an `NSTextAttachment`.
///
/// One web view, reused for every render (creating a fresh `WKWebView` per block would multiply
/// the ~150ms process-launch cost of WebKit's content process across every table/equation/diagram
/// in a document). Requests are serialized through it one at a time — `#stage` in `index.html` is a
/// single shared render surface, so two renders in flight at once would clobber each other's DOM.
///
/// **Never talks to the network.** `index.html`'s own CSP (`default-src 'self'; script-src 'self'
/// 'unsafe-eval'; connect-src 'none'`) is the enforced boundary; KaTeX and Mermaid are bundled in
/// the app (`App/Resources/LivePreviewRender/`), loaded via `loadFileURL(_:allowingReadAccessTo:)`
/// rather than any remote URL.
///
/// **Caching.** Every render is keyed by a SHA-256 of its kind, content, and target scale — an
/// in-memory `NSCache`, evicted under memory pressure and never persisted across launches (see this
/// type's doc comment in the PR notes for why disk persistence was left out: the in-memory cache
/// already satisfies "only edited blocks re-render" for the lifetime that matters, a single editing
/// session, and every render is idempotent/cheap to redo on the next launch). A block whose source
/// text hasn't changed since the last render never touches the web view again.
final class BlockImageRenderer: NSObject {

    static let shared = BlockImageRenderer()

    enum Kind: String {
        case table, inlineMath, displayMath, mermaid
    }

    /// Which of the app's two visual appearances a render should match — resolved by the caller
    /// (`LivePreviewController`) from the editor's *effective* appearance, not simply
    /// `EditorSettings.Theme`: `Theme.system` itself isn't light or dark, and this renderer needs
    /// one concrete answer to inject the right CSS/Mermaid theme for a given render.
    enum Appearance: String {
        case light, dark

        /// Resolves from whatever `NSAppearance` is actually in effect (the app-wide appearance
        /// `EditorSettings.applyTheme()` sets, which already folds `.system` down to whatever the
        /// OS is currently in) — see call site in `LivePreviewController` for why this reads
        /// `NSApp.effectiveAppearance` rather than re-deriving `EditorSettings.Theme` itself.
        static func resolve(from appearance: NSAppearance) -> Appearance {
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light
        }
    }

    private var webView: WKWebView!
    private var hostWindow: NSWindow!
    private var isReady = false
    private var pendingReadyCallbacks: [() -> Void] = []
    private var requestQueue: [() -> Void] = []
    private var isProcessingQueue = false

    private let cache = NSCache<NSString, NSImage>()
    private static var mermaidRenderCounter = 0

    private override init() {
        super.init()
        cache.countLimit = 200
        // Deliberately *not* a direct `setUpWebView()` call here — see this file's PR notes for a
        // real crash this caused. Constructing the very first `WKWebView` in the process creates
        // WebKit's `WebProcessPool`, whose init calls `-[NSUserDefaults registerDefaults:]`, which
        // posts `UserDefaults.didChangeNotification` *synchronously* — reentering
        // `EditorViewController`'s settings observer, which reaches `kickOffPendingRenders()`,
        // which reads `BlockImageRenderer.shared` again while this very `static let` initializer is
        // still on the stack. Swift's runtime traps hard on that (`EXC_BREAKPOINT` in
        // `_dispatch_once_wait`) rather than deadlocking quietly. Scheduling the actual web view
        // setup one run-loop turn later means `shared`'s initializer has already returned — and its
        // internal lock released — by the time WebKit does whatever `UserDefaults` dance it does on
        // first launch, so a reentrant notification lands on an already-fully-constructed
        // singleton instead of a half-built one.
        DispatchQueue.main.async { [weak self] in
            self?.setUpWebView()
        }
    }

    // MARK: - Setup

    private func setUpWebView() {
        let configuration = WKWebViewConfiguration()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        // A blank data store as far from "the user's browsing" as this API allows — this web view
        // never visits anything but the one bundled local file, so persistence, cookies, and cache
        // sharing with any other web view in the process are all pure downside.
        configuration.websiteDataStore = .nonPersistent()

        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 1400, height: 200), configuration: configuration)
        view.navigationDelegate = self
        // `WKWebView` paints an opaque white page background by default, entirely independent of
        // `index.html`'s own `background: transparent` — that CSS only controls what the *page's
        // own content* draws, not the web view's backing fill underneath it. Left as-is, every
        // rendered block came back with a hard white rectangle baked into the snapshot, which read
        // as "a screenshot pasted into the document" in dark mode (light background, black text,
        // no relation to the editor's actual appearance). There is no public API for this — the
        // `drawsBackground` KVC key is WebKit's own long-standing (if undocumented) mechanism for
        // it, used widely for exactly this "offscreen/embedded content should inherit the host's
        // background" case. With it off, the PNG this class snapshots is truly transparent, so the
        // block sits directly on `NSTextView`'s own `.textBackgroundColor` wherever it's embedded —
        // correct in light mode, dark mode, and any future appearance, with no color to keep in
        // sync by hand.
        view.setValue(false, forKey: "drawsBackground")
        // Belt-and-suspenders alongside the KVC key above: `underPageBackgroundColor` is the
        // *public*, documented API for the same intent (the color shown in the scroll-bounce
        // area/outside the page's own content), and some WebKit versions have been observed to let
        // it influence what `takeSnapshot(with:completionHandler:)` composites against even when
        // `drawsBackground` alone left a snapshot opaque. Costs nothing to set both.
        view.underPageBackgroundColor = .clear
        webView = view

        // Hosted in a real (but effectively invisible) window rather than left unparented: an
        // unparented WKWebView's layer has no reliable backing scale factor to render at, which is
        // exactly the "blurry on Retina" failure mode the task brief calls out by name. Sitting a
        // near-zero-alpha window over the main screen gives the web view the *real* display's
        // backing scale (2x on Retina) for free, while `ignoresMouseEvents` and never calling
        // `makeKey`/activating keep it from ever intercepting a click or stealing focus from a real
        // document window.
        let window = NSWindow(
            contentRect: NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1400, height: 900),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.alphaValue = 0.01
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.level = .init(Int(CGWindowLevelForKey(.desktopIconWindow)) - 1)
        window.contentView = NSView(frame: window.contentView?.bounds ?? .zero)
        window.contentView?.addSubview(view)
        window.orderFrontRegardless()
        hostWindow = window

        let resourceDirectory = Bundle.main.resourceURL?.appendingPathComponent("LivePreviewRender")
        guard let resourceDirectory, let indexURL = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "LivePreviewRender") else {
            assertionFailure("LivePreviewRender resources missing from the app bundle")
            return
        }
        view.loadFileURL(indexURL, allowingReadAccessTo: resourceDirectory)
    }

    private func whenReady(_ body: @escaping () -> Void) {
        if isReady {
            body()
        } else {
            pendingReadyCallbacks.append(body)
        }
    }

    // MARK: - Public API

    /// Renders `content` (already-extracted source text — the math expression without its `$`/`$$`
    /// delimiters, the Mermaid fence's inner text, or `MarkdownTableHTML`-produced HTML for a
    /// table) at `scale` (pass the screen's `backingScaleFactor` so the embedded attachment reads
    /// crisply on Retina), calling `completion` on the main queue with the resulting image, or
    /// `nil` if rendering failed (a malformed diagram, say — the caller falls back to showing raw
    /// source rather than an attachment for a failed render, since a blank/broken image would be
    /// strictly worse than the text it was replacing).
    ///
    /// - Parameters:
    ///   - appearance: Which of the app's two appearances to render CSS/Mermaid colors for — part
    ///     of the cache key (see `cacheKey(...)`), so a theme change never serves a stale image
    ///     rendered for the other appearance.
    ///   - targetWidth: The current text container's available width in points — a `.table` render
    ///     stretches to fill it (wrapping cells only when their content genuinely needs more room)
    ///     rather than shrink-wrapping to its narrowest possible width; other kinds size themselves
    ///     naturally and ignore it. Also part of the cache key, so a resized window or a measure
    ///     change never serves a stale width's image.
    func render(kind: Kind, content: String, scale: CGFloat, appearance: Appearance, targetWidth: CGFloat, completion: @escaping (NSImage?) -> Void) {
        let key = Self.cacheKey(kind: kind, content: content, scale: scale, appearance: appearance, targetWidth: targetWidth)
        if let cached = cache.object(forKey: key as NSString) {
            completion(cached)
            return
        }

        enqueue { [weak self] in
            guard let self else { completion(nil); return }
            self.performRender(kind: kind, content: content, scale: scale, appearance: appearance, targetWidth: targetWidth) { image in
                if let image {
                    self.cache.setObject(image, forKey: key as NSString)
                }
                completion(image)
                self.isProcessingQueue = false
                self.dequeueNext()
            }
        }
    }

    /// Keyed on everything that can change what the rendered pixels actually look like — `kind`
    /// and `content` obviously, but also `scale` (Retina vs. not), `appearance` (light vs. dark
    /// CSS/Mermaid theme), and `targetWidth` (a `.table`'s wrap width). Any one of these differing
    /// between two requests for otherwise-identical content must **not** hit the same cache entry,
    /// or a resized window/theme change would silently keep showing the old rendering.
    private static func cacheKey(kind: Kind, content: String, scale: CGFloat, appearance: Appearance, targetWidth: CGFloat) -> String {
        let roundedWidth = (targetWidth * 2).rounded() / 2 // half-point precision: plenty for layout, avoids float-noise cache misses
        let digest = SHA256.hash(data: Data("\(kind.rawValue)|\(scale)|\(appearance.rawValue)|\(roundedWidth)|\(content)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Resolves the CSS-ready colors for `appearance`, independent of whatever appearance is
    /// actually active on screen right now — `NSAppearance.performAsCurrentDrawingAppearance(_:)`
    /// makes every dynamic `NSColor` read inside the closure resolve as if `appearance` were the
    /// active one, which is what lets this renderer produce a correct dark-mode image even while
    /// the rest of the app (or the reverse) is light, or vice versa, without touching any real
    /// window's actual appearance.
    private static func themePayload(for appearance: Appearance) -> [String: Any] {
        let nsAppearance = NSAppearance(named: appearance == .dark ? .darkAqua : .aqua) ?? NSAppearance()
        var foreground = "#000000"
        var border = "rgba(0,0,0,0.25)"
        var headerBackground = "rgba(0,0,0,0.06)"
        nsAppearance.performAsCurrentDrawingAppearance {
            foreground = cssColor(.labelColor)
            border = cssColor(.separatorColor)
            headerBackground = cssColor(NSColor.labelColor.withAlphaComponent(0.06))
        }
        return [
            "foreground": foreground,
            "border": border,
            "headerBackground": headerBackground,
            "isDark": appearance == .dark,
        ]
    }

    /// `color`, resolved against whatever appearance is current when called (see
    /// `themePayload(for:)`'s `performAsCurrentDrawingAppearance` wrapper), as a CSS `rgba(...)`
    /// string the offscreen page's injected `<style>` can use directly.
    private static func cssColor(_ color: NSColor) -> String {
        let rgb = color.usingColorSpace(.deviceRGB) ?? color
        let r = Int((rgb.redComponent * 255).rounded())
        let g = Int((rgb.greenComponent * 255).rounded())
        let b = Int((rgb.blueComponent * 255).rounded())
        return "rgba(\(r), \(g), \(b), \(rgb.alphaComponent))"
    }

    // MARK: - Serial queue

    private func enqueue(_ work: @escaping () -> Void) {
        DispatchQueue.main.async {
            self.requestQueue.append(work)
            self.dequeueNext()
        }
    }

    private func dequeueNext() {
        DispatchQueue.main.async {
            guard !self.isProcessingQueue, !self.requestQueue.isEmpty else { return }
            self.isProcessingQueue = true
            let next = self.requestQueue.removeFirst()
            next()
        }
    }

    // MARK: - Rendering

    private func performRender(kind: Kind, content: String, scale: CGFloat, appearance: Appearance, targetWidth: CGFloat, completion: @escaping (NSImage?) -> Void) {
        whenReady { [weak self] in
            guard let self else { completion(nil); return }

            // CSS px and points coincide 1:1 in this web view — see `render(...)`'s doc comment —
            // so `targetWidth` (already in points) is handed to the page verbatim, no scale
            // conversion needed. The real Retina resolution comes from the *host window*'s actual
            // backing scale (see `setUpWebView`'s doc comment), not from anything JS is told here.
            let theme = Self.themePayload(for: appearance)

            let call: (String, [String: Any])
            switch kind {
            case .inlineMath:
                call = ("return await mdedRenderMath(latex, displayMode, theme);", ["latex": content, "displayMode": false, "theme": theme])
            case .displayMath:
                call = ("return await mdedRenderMath(latex, displayMode, theme);", ["latex": content, "displayMode": true, "theme": theme])
            case .table:
                call = ("return await mdedRenderTableHTML(html, theme, targetWidth);", ["html": content, "theme": theme, "targetWidth": Double(targetWidth)])
            case .mermaid:
                Self.mermaidRenderCounter += 1
                call = ("return await mdedRenderMermaid(code, id, theme);", ["code": content, "id": "mded-mermaid-\(Self.mermaidRenderCounter)", "theme": theme])
            }

            self.webView.callAsyncJavaScript(call.0, arguments: call.1, in: nil, in: .page) { [weak self] result in
                guard let self else { completion(nil); return }
                guard case .success(let value) = result,
                      let sizeDict = value as? [String: Any],
                      let widthPx = sizeDict["width"] as? Double,
                      let heightPx = sizeDict["height"] as? Double,
                      widthPx > 0, heightPx > 0
                else {
                    completion(nil)
                    return
                }

                let contentSize = NSSize(width: widthPx, height: heightPx)
                self.webView.setFrameSize(contentSize)

                let config = WKSnapshotConfiguration()
                config.rect = NSRect(origin: .zero, size: contentSize)
                config.afterScreenUpdates = true

                self.webView.takeSnapshot(with: config) { image, _ in
                    completion(image)
                }
            }
        }
    }
}

extension BlockImageRenderer: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isReady = true
        let callbacks = pendingReadyCallbacks
        pendingReadyCallbacks.removeAll()
        callbacks.forEach { $0() }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        assertionFailure("LivePreviewRender/index.html failed to load: \(error)")
    }
}
