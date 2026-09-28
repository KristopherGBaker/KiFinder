import Photos

/// Authorization seam (item 54, `ModelDownloadClient` style): lets a test drive
/// `LiveTriageEngine.exportToPhotos`'s authorization branch with a deterministic
/// status (denied/limited/authorized) WITHOUT ever touching the real
/// `PHPhotoLibrary` from the test host process.
protocol PhotosAuthorizationClient: Sendable {
    /// Requests add-only authorization and returns the resulting status.
    func requestAddOnlyAuthorization() async -> PHAuthorizationStatus
}

/// Production client: the real system prompt/status, unchanged from before item 54.
struct SystemPhotosAuthorizationClient: PhotosAuthorizationClient {
    func requestAddOnlyAuthorization() async -> PHAuthorizationStatus {
        await PHPhotoLibrary.requestAuthorization(for: .addOnly)
    }
}
