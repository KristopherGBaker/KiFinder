import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The album-scan "moment": a dark `inkInverse` surface presented over Review.
/// Idle, it accepts a folder OR a .zip (drag-and-drop or a file picker); during
/// a scan it shows live progress — album name, determinate bar + %, matches so
/// far, an on-device privacy badge, time left, and Stop. On completion it routes
/// back to Review with the scan's candidates.
struct ScanSheet: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // Scroll the body so large accessibility text can't clip it (there was no
            // internal ScrollView before); the footer stays pinned below.
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    if let message = model.scanError {
                        errorCard(message)
                    }
                    if model.isScanning {
                        progressCard
                    } else {
                        dropCard
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            footer
        }
        .padding(28)
        // Content-driven sizing (not a fixed 460) so the sheet grows for large text
        // and shrinks onto small displays rather than clipping.
        .frame(minWidth: 480, idealWidth: 560, minHeight: 360, idealHeight: 460)
        .background(DesignColor.inkInverse)
        .preferredColorScheme(.dark)
        // The terminal scan tick applies the candidates; routing to Review is just
        // dismissing this sheet so the populated grid shows behind it.
        .onChange(of: model.scanComplete) { _, complete in
            if complete { model.dismissScan() }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Scan an album")
                .kionFont(24, weight: .semibold, design: .rounded)
                .foregroundStyle(.white)
                .accessibilityIdentifier("Scan an album")
            Text("One gesture starts a local scan. This archive is unzipped, matched against the people you've enrolled, then forgotten.")
                .kionFont(12)
                .foregroundStyle(.white.opacity(0.7))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Idle drop card

    private var dropCard: some View {
        VStack(spacing: 14) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 34))
                .foregroundStyle(.white.opacity(0.85))
            Text("Drop albums")
                .kionFont(16, weight: .semibold)
                .foregroundStyle(.white)
            Text("Folders or .zips — drop several at once; nested folders are traversed.")
                .kionFont(11)
                .foregroundStyle(.white.opacity(0.6))

            HStack(spacing: 12) {
                Button("Choose Albums…") { chooseAlbum() }
                    .buttonStyle(.bordered)
                    .tint(.white)
                    .accessibilityIdentifier("Choose Albums…")

                if model.showsScanTestAffordance {
                    Button("Scan Sample Album") {
                        model.startScan(albums: [URL(fileURLWithPath: "/tmp/June-preschool.zip")])
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(DesignColor.keep)
                    .accessibilityIdentifier("scan-sample-album")
                }
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(.white.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                .foregroundStyle(.white.opacity(0.25))
        )
        .dropDestination(for: URL.self) { urls, _ in
            guard !urls.isEmpty else { return false }
            model.startScan(albums: urls)
            return true
        }
    }

    // MARK: - Error card

    /// A recoverable scan-failure banner: a localized message plus Try Again /
    /// Dismiss. Shown instead of routing the (empty) failure into Review.
    private func errorCard(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .kionFont(13, weight: .semibold)
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("scanErrorMessage")
            HStack(spacing: 12) {
                Button("Try Again") { model.retryScan() }
                    .buttonStyle(.borderedProminent)
                    .tint(DesignColor.keep)
                    .accessibilityIdentifier("scanErrorRetryButton")
                Button("Dismiss") { model.clearScanError() }
                    .buttonStyle(.bordered)
                    .tint(.white)
                    .accessibilityIdentifier("scanErrorDismissButton")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(Color.red.opacity(0.22))
        )
    }

    // MARK: - In-progress card

    private var progressCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(model.scanAlbumName)
                .kionFont(15, weight: .semibold, design: .monospaced)
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.middle)
                .accessibilityIdentifier("scan-album-name")

            VStack(alignment: .leading, spacing: 6) {
                if model.scanIndeterminate {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .tint(DesignColor.keep)
                    Text("Scanning…")
                        .kionFont(12, design: .monospaced)
                        .foregroundStyle(.white.opacity(0.8))
                        .accessibilityIdentifier("scan-progress")
                } else {
                    ProgressView(value: model.scanProgress)
                        .tint(DesignColor.keep)
                    Text(verbatim: "\(Int((model.scanProgress * 100).rounded()))%")
                        .kionFont(12, design: .monospaced)
                        .foregroundStyle(.white.opacity(0.8))
                        .accessibilityIdentifier("scan-progress")
                }
            }

            // Live status: "<n> of <total> · <album>" (and "Album i of n" for a batch).
            if !model.scanStatusText.isEmpty {
                Text(model.scanStatusText)
                    .kionFont(11)
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityIdentifier("scan-status")
            }

            // Each stat is a direct VStack child (not grouped in an HStack):
            // XCUITest on macOS surfaces these leaf identifiers reliably this way,
            // whereas Texts nested inside an HStack did not.
            stat(String(localized: "\(model.scanMatchesSoFar) matches"), id: "scan-matches")
            onDeviceBadge

            Button("Stop") { model.stopScan() }
                .buttonStyle(.bordered)
                .tint(.white)
                .accessibilityIdentifier("Stop")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(.white.opacity(0.06))
        )
    }

    /// A single-`Text` stat. One Text (not two stacked Texts) so SwiftUI doesn't
    /// auto-combine them into one element and drop this identifier — the same
    /// shape as the working `scan-progress` label.
    private func stat(_ text: String, id: String) -> some View {
        Text(text)
            .kionFont(13, weight: .medium)
            .foregroundStyle(.white)
            .accessibilityIdentifier(id)
    }

    private var onDeviceBadge: some View {
        Label("On-device · 100%", systemImage: "lock.fill")
            .kionFont(11, weight: .semibold)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(DesignColor.keep.opacity(0.22), in: Capsule())
            .foregroundStyle(DesignColor.keep)
            .accessibilityElement(children: .ignore)
            .accessibilityIdentifier("On-device · 100%")
            .accessibilityLabel("On-device · 100%")
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Spacer()
            Button("Cancel", role: .cancel) { model.dismissScan() }
                .disabled(model.isScanning)
                .accessibilityIdentifier("scan-cancel")
        }
    }

    // MARK: - File picker

    private func chooseAlbum() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        // Folders, .zips, AND loose image files — a single image is scanned as just
        // that file (see ScanPipeline / LiveTriageEngine album resolution).
        panel.allowedContentTypes = [.zip, .folder, .image]
        panel.prompt = String(localized: "Scan")
        if panel.runModal() == .OK, !panel.urls.isEmpty {
            model.startScan(albums: panel.urls)
        }
    }
}
