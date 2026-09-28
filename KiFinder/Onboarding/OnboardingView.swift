import SwiftUI

/// First-run gate UI: explains the one-time model download and drives the
/// `ModelDownloader` through download → verify → install. On success the app's
/// `needsOnboarding` flips to false (observable, no relaunch) and Review appears.
/// The download-size copy is DERIVED from the active downloader's descriptor
/// (item74b) — ~249 MB for the default ArcFace ONNX backend, ~44 MB for AdaFace
/// (CoreML) — never a second hardcoded literal.
struct OnboardingView: View {
    @Bindable var model: AppModel

    private var downloader: ModelDownloader {
        model.modelDownloader
    }

    private var expectedSizeText: String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: downloader.expectedByteCount)
    }

    var body: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 0)

            Image(systemName: "person.crop.square.badge.camera")
                .font(.system(size: 52, weight: .regular))
                .foregroundStyle(DesignColor.keep)

            VStack(spacing: 10) {
                Text("Set up KiFinder")
                    .kionFont(26, weight: .semibold, design: .rounded)
                    .foregroundStyle(DesignColor.ink)
                    // The onboarding marker, on a LEAF — putting it on the root container
                    // (below) propagates and overrides child ids (libraryRootField,
                    // onboardingDownloadButton), exactly like the libraryBrowseView fix.
                    .accessibilityIdentifier("onboardingView")
                Text("KiFinder finds your people entirely on your Mac. To do that it needs a one-time, ~\(expectedSizeText) face-recognition model. It downloads once and stays on this Mac — no photos ever leave the device.")
                    .kionFont(13)
                    .foregroundStyle(DesignColor.inkSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 420)
            }

            content
                .frame(maxWidth: 420)

            // The library-root control is additive and NON-gating: it has a default,
            // so it never blocks the model-download readiness gate above.
            LibraryRootControl(model: model)
                .frame(maxWidth: 420)

            Spacer(minLength: 0)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DesignColor.canvas)
    }

    @ViewBuilder
    private var content: some View {
        switch downloader.state {
        case .idle:
            downloadButton

        case let .downloading(fraction, written, total):
            progressView(fraction: fraction, written: written, total: total)

        case .verifying:
            VStack(spacing: 8) {
                ProgressView()
                Text("Verifying…")
                    .kionFont(12)
                    .foregroundStyle(DesignColor.inkSecondary)
                    .accessibilityIdentifier("onboardingProgress")
            }

        case .installed:
            Label("Ready", systemImage: "checkmark.circle.fill")
                .kionFont(14, weight: .semibold)
                .foregroundStyle(DesignColor.keep)

        case let .failed(message):
            VStack(spacing: 12) {
                Text(message)
                    .kionFont(12)
                    .foregroundStyle(DesignColor.maybe)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Retry Download") { downloader.retry() }
                    .buttonStyle(.borderedProminent)
                    .tint(DesignColor.keep)
                    .accessibilityIdentifier("onboardingRetryButton")
            }
        }
    }

    private var downloadButton: some View {
        Button {
            downloader.start()
        } label: {
            Text("Download Model (~\(expectedSizeText))")
                .frame(minWidth: 220)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .tint(DesignColor.keep)
        .accessibilityIdentifier("onboardingDownloadButton")
    }

    private func progressView(fraction: Double, written: Int64, total: Int64) -> some View {
        VStack(spacing: 10) {
            ProgressView(value: fraction)
                .progressViewStyle(.linear)
                .accessibilityIdentifier("onboardingProgress")
                .accessibilityValue(Text(percentText(fraction)))
            HStack {
                Text(percentText(fraction))
                Spacer()
                Text(byteText(written: written, total: total))
            }
            .kionFont(11)
            .foregroundStyle(DesignColor.inkSecondary)

            Button("Cancel") { downloader.cancel() }
                .buttonStyle(.borderless)
                .kionFont(11)
        }
    }

    private func percentText(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))%"
    }

    private func byteText(written: Int64, total: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useMB]
        formatter.countStyle = .file
        let writtenMB = formatter.string(fromByteCount: written)
        let totalMB = formatter.string(fromByteCount: total)
        return "\(writtenMB) / \(totalMB)"
    }
}
