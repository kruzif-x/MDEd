import Cocoa
import SwiftUI

/// Backs one AI review sheet — see `AIReview.present(...)`. `@MainActor` because every mutation
/// drives SwiftUI state directly; the `Task` that runs the actual AI command hops back to the main
/// actor to report progress and the final result (or failure) into this model.
@MainActor
final class AIReviewModel: ObservableObject {
    enum State {
        case running(AIProgress)
        case success(String)
        case failure(String)
    }

    let title: String
    /// The apply button's label (e.g. "Replace Selection"), or `nil` when this command has nothing
    /// to apply to a document — a diff summary, say, which is read and dismissed, not inserted
    /// anywhere. `onApply` mirrors this: both are set together or not at all.
    let applyLabel: String?
    @Published var state: State

    var onCancel: () -> Void = {}
    var onApply: ((String) -> Void)?
    var onDismiss: () -> Void = {}

    init(title: String, applyLabel: String?, state: State) {
        self.title = title
        self.applyLabel = applyLabel
        self.state = state
    }
}

/// The single review surface every AI command in MDEd results in — see this project's own rule:
/// results are always presented for review with an explicit apply/discard choice, never applied to
/// the document on their own. One shared view (rather than one per command) keeps that guarantee
/// structural: there is exactly one place a result can reach `onApply`, and it's a button the user
/// clicked.
struct AIReviewView: View {
    @ObservedObject var model: AIReviewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(model.title)
                .font(.headline)

            content

            HStack {
                Spacer()
                footer
            }
        }
        .padding(20)
        .frame(width: 480)
    }

    @ViewBuilder private var content: some View {
        switch model.state {
        case .running(let progress):
            VStack(alignment: .leading, spacing: 8) {
                if progress.total > 0 {
                    ProgressView(value: Double(progress.completed), total: Double(progress.total))
                } else {
                    ProgressView()
                }
                Text(progress.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 90, alignment: .center)

        case .failure(let message):
            Text(message)
                .foregroundStyle(.red)
                .frame(maxWidth: .infinity, minHeight: 90, alignment: .center)
                .multilineTextAlignment(.center)

        case .success(let text):
            ScrollView {
                Text(text)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(minHeight: 220, maxHeight: 380)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    @ViewBuilder private var footer: some View {
        switch model.state {
        case .running:
            Button("Cancel") { model.onCancel() }

        case .failure:
            Button("Close") { model.onDismiss() }
                .keyboardShortcut(.defaultAction)

        case .success(let text):
            Button("Copy") { copyToPasteboard(text) }
            Button("Discard") { model.onDismiss() }
            if let label = model.applyLabel, let onApply = model.onApply {
                Button(label) {
                    onApply(text)
                    model.onDismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// Presents one AI command's result as a sheet on a document window, owning the cancellable `Task`
/// that runs it.
@MainActor
enum AIReview {

    /// - Parameters:
    ///   - operation: The AI command itself — given a progress callback, returns the final text or
    ///     throws. Run inside a `Task` so `model.onCancel` (wired to the sheet's Cancel button) can
    ///     call `Task.cancel()`; the operation is expected to check `Task.checkCancellation()`
    ///     between its own steps (see `AICommandRunner`).
    ///   - onApply: Called with the result only if the user clicks the apply button — never
    ///     automatically. `nil` when this command has nothing to apply (see `AIReviewModel`).
    static func present(
        title: String,
        applyLabel: String?,
        over window: NSWindow,
        operation: @escaping (@escaping (AIProgress) -> Void) async throws -> String,
        onApply: ((String) -> Void)? = nil
    ) {
        let model = AIReviewModel(
            title: title,
            applyLabel: applyLabel,
            state: .running(AIProgress(completed: 0, total: 0, message: "Starting…"))
        )
        model.onApply = onApply

        let hosting = NSHostingController(rootView: AIReviewView(model: model))
        let sheetWindow = NSWindow(contentViewController: hosting)
        sheetWindow.styleMask = [.titled]
        sheetWindow.titlebarAppearsTransparent = true
        sheetWindow.titleVisibility = .hidden

        var task: Task<Void, Never>?
        model.onCancel = { task?.cancel() }
        model.onDismiss = {
            task?.cancel()
            window.endSheet(sheetWindow)
        }

        window.beginSheet(sheetWindow)

        task = Task { @MainActor in
            do {
                let result = try await operation { progress in
                    model.state = .running(progress)
                }
                guard !Task.isCancelled else { return }
                model.state = .success(result)
            } catch is CancellationError {
                // The user already dismissed the sheet via Cancel — nothing further to show.
                if window.attachedSheet === sheetWindow {
                    window.endSheet(sheetWindow)
                }
            } catch {
                guard !Task.isCancelled else { return }
                model.state = .failure(error.localizedDescription)
            }
        }
    }
}
