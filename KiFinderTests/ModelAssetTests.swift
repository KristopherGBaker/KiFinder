import Foundation
@testable import KiFinder
import Testing

@Suite("Model asset descriptor")
struct ModelAssetTests {
    @Test("Production descriptor pins the exact fixed inputs")
    func productionEqualsFixedInputs() {
        let production = ModelAssetDescriptor.production

        #expect(production.downloadURL == URL(string: "https://huggingface.co/onnxmodelzoo/arcfaceresnet100-8/resolve/main/arcfaceresnet100-8.onnx?download=true"))
        #expect(production.expectedByteCount == 261_036_388)
        #expect(production.expectedSHA256 == "f3a6bc281e72f88862f5748b53be3d76b3b48f8f1ab1f4a537941bdc4e1b01da")
        #expect(production.fileName == "arcfaceresnet100-8.onnx")
        // The hash is stored lowercase (so verification compares like-for-like).
        #expect(production.expectedSHA256 == production.expectedSHA256.lowercased())
        // .production keeps move-file semantics: installedName == fileName.
        #expect(production.installedName == production.fileName)
        #expect(production.installKind == .moveFile)
    }

    // MARK: - item74b: .adaface pin + init defaulting

    @Test("AdaFace descriptor pins the exact fixed inputs")
    func adafaceEqualsFixedInputs() {
        let adaface = ModelAssetDescriptor.adaface

        #expect(adaface.downloadURL == URL(string: "https://github.com/john-rocky/CoreML-Models/releases/download/adaface-v1/AdaFace_IR18.mlpackage.zip"))
        #expect(adaface.expectedByteCount == 44_482_098)
        #expect(adaface.expectedSHA256 == "c639ffc02233c72c10daf90f484e14bf570b7f70f55f0c0ee1ce3d284a04430b")
        #expect(adaface.fileName == "AdaFace_IR18.mlpackage.zip")
        #expect(adaface.installedName == "AdaFace_IR18.mlmodelc")
        #expect(adaface.installKind == .unzipAndCompileMLModel)
        // The hash is stored lowercase (so verification compares like-for-like).
        #expect(adaface.expectedSHA256 == adaface.expectedSHA256.lowercased())
    }

    @Test("A descriptor constructed without installedName/installKind defaults to fileName/.moveFile")
    func initDefaultingPreservesMoveFileSemantics() {
        // A non-production test descriptor (mirrors ModelDownloaderTests'
        // fixtureDescriptor / OnboardingGateTests' inline descriptor call
        // sites) — proves every EXISTING call site that never mentions the two
        // new params keeps move-file semantics.
        let descriptor = ModelAssetDescriptor(
            downloadURL: URL(string: "https://example.com/fixture.onnx")!,
            expectedByteCount: 1234,
            expectedSHA256: "deadbeef",
            fileName: "fixture.onnx"
        )

        #expect(descriptor.installedName == "fixture.onnx")
        #expect(descriptor.installedName == descriptor.fileName)
        #expect(descriptor.installKind == .moveFile)
    }
}
