import SwiftUI

/// First-run backend chooser (item 73): shown BEFORE the onboarding download
/// gate, so picking Vision never triggers the ~249 MB ArcFace download at all.
/// The choice is reported upward via `onChoose` — this view never persists or
/// reconstructs anything itself; `AppModel.chooseFirstRunBackend` (called by the
/// App from `onChoose`) owns persisting the pick, and the App owns rebuilding
/// its `@State AppModel` when that's required to apply it.
struct BackendChoiceView: View {
    @Bindable var model: AppModel
    let onChoose: (FaceBackend) -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 0)

            Image(systemName: "person.crop.square.badge.magnifyingglass")
                .font(.system(size: 52, weight: .regular))
                .foregroundStyle(DesignColor.keep)

            VStack(spacing: 10) {
                Text("Choose a face-recognition backend")
                    .kionFont(26, weight: .semibold, design: .rounded)
                    .foregroundStyle(DesignColor.ink)
                    // The chooser marker, on a LEAF — putting it on the root
                    // container propagates and overrides child ids (the two
                    // choice buttons below), exactly like OnboardingView's note.
                    .accessibilityIdentifier("backendChoiceView")
                Text("KiFinder finds your people entirely on your Mac. Pick which face-recognition model it uses — you can change this later in Settings.")
                    .kionFont(13)
                    .foregroundStyle(DesignColor.inkSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 420)
            }

            VStack(spacing: 12) {
                choiceButton(
                    title: "ArcFace",
                    detail: "Most accurate on-device face matching. One-time ~249 MB download.",
                    identifier: "backendChoiceArcFaceButton"
                ) {
                    onChoose(.onnx)
                }
                choiceButton(
                    title: "Vision",
                    detail: "Built into macOS — no download. Less face-tuned than ArcFace.",
                    identifier: "backendChoiceVisionButton"
                ) {
                    onChoose(.vision)
                }
                choiceButton(
                    title: "AdaFace",
                    detail: "Most accurate on-device face matching. One-time ~44 MB download.",
                    identifier: "backendChoiceCoreMLButton"
                ) {
                    onChoose(.coreml)
                }
            }
            .frame(maxWidth: 420)

            Spacer(minLength: 0)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DesignColor.canvas)
    }

    private func choiceButton(
        title: String,
        detail: String,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .kionFont(15, weight: .semibold)
                Text(detail)
                    .kionFont(12)
                    .foregroundStyle(DesignColor.inkSecondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 8)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .tint(DesignColor.keep)
        .accessibilityIdentifier(identifier)
    }
}
