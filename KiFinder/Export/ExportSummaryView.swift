import AppKit
import SwiftUI

/// Post-export confirmation: how many kept photos were copied, where they went,
/// and a way to reveal them. Straight copies — originals are never touched.
struct ExportSummaryView: View {
    @Bindable var model: AppModel

    private var headline: String {
        String(localized: "Exported \(model.exportedCount) photos")
    }

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(DesignColor.keep)

            Text(headline)
                .kionFont(20, weight: .semibold, design: .rounded)
                .accessibilityIdentifier("export-headline")

            if let destination = model.exportDestination {
                Text(destination.path)
                    .kionFont(11, design: .monospaced)
                    .foregroundStyle(DesignColor.inkSecondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .multilineTextAlignment(.center)
            } else {
                Text("Added to your Photos library.")
                    .kionFont(12)
                    .foregroundStyle(DesignColor.inkSecondary)
            }

            HStack(spacing: 12) {
                if let destination = model.exportDestination {
                    Button("Show in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([destination])
                    }
                    .accessibilityIdentifier("Show in Finder")
                }
                Button("Done") { model.dismissExportSummary() }
                    .buttonStyle(.borderedProminent)
                    .tint(DesignColor.keep)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("export-done")
            }
        }
        .padding(28)
        .frame(width: 380)
        .background(DesignColor.surface)
        .accessibilityIdentifier("export-success")
    }
}
