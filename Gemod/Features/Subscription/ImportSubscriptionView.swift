import SwiftUI
import Photos

struct ImportSubscriptionView: View {
    let onImportURL: (String) -> Void
    let onImportFromClipboard: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var latestImage: UIImage?
    @State private var isLoadingLatestPhoto = false
    @State private var alertMessage: String?

    var body: some View {
        NavigationView {
            VStack(spacing: 16) {
                ZStack(alignment: .bottomLeading) {
                    QRScannerView { code in
                        guard let url = URL(string: code),
                              let scheme = url.scheme?.lowercased(),
                              ["http", "https"].contains(scheme) else {
                            alertMessage = AppLanguage.useSimplifiedChinese ? "未识别到二维码" : "QR code not recognized"
                            return
                        }
                        onImportURL(code)
                        dismiss()
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 14))

                    Text(AppLanguage.useSimplifiedChinese ? "请将二维码放入取景框" : "Place QR code in frame")
                        .font(.footnote)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.ultraThinMaterial)
                        .clipShape(Capsule())
                        .padding(12)
                }
                .frame(maxWidth: .infinity)
                .aspectRatio(1, contentMode: .fit)

                HStack(spacing: 12) {
                    Button {
                        importFromLatestPhoto()
                    } label: {
                        ZStack {
                            RoundedRectangle(cornerRadius: 14)
                                .fill(Color(.secondarySystemBackground))
                            if let image = latestImage {
                                Image(uiImage: image)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 120, height: 120)
                                    .clipped()
                                    .clipShape(RoundedRectangle(cornerRadius: 14))
                            } else if isLoadingLatestPhoto {
                                ProgressView()
                            } else {
                                VStack(spacing: 8) {
                                    Image(systemName: "photo")
                                    Text(AppLanguage.useSimplifiedChinese ? "最近照片" : "Latest Photo")
                                        .font(.footnote)
                                }
                                .foregroundStyle(.secondary)
                            }
                        }
                        .frame(width: 120, height: 120)
                    }
                    .buttonStyle(.plain)

                    Button {
                        onImportFromClipboard()
                        dismiss()
                    } label: {
                        VStack(spacing: 8) {
                            Image(systemName: "clipboard")
                                .font(.title3)
                            Text(AppLanguage.useSimplifiedChinese ? "从剪切板导入" : "Import from Clipboard")
                                .font(.footnote)
                        }
                        .frame(width: 120, height: 120)
                        .background(Color(.secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                    .buttonStyle(.plain)
                }

                Spacer()
            }
            .padding()
            .navigationTitle(AppLanguage.useSimplifiedChinese ? "导入订阅" : "Import Subscription")
            .navigationBarTitleDisplayMode(.inline)
            .alert(AppLanguage.useSimplifiedChinese ? "提示" : "Notice", isPresented: Binding(
                get: { alertMessage != nil },
                set: { if !$0 { alertMessage = nil } }
            ), actions: {
                Button(AppLanguage.useSimplifiedChinese ? "确定" : "OK") {
                    alertMessage = nil
                }
            }, message: {
                Text(alertMessage ?? "")
            })
            .task {
                await loadLatestPhoto()
            }
        }
    }

    private func importFromLatestPhoto() {
        if isLoadingLatestPhoto {
            alertMessage = AppLanguage.useSimplifiedChinese ? "正在加载最近照片，请稍候" : "Loading latest photo, please wait"
            return
        }
        guard let image = latestImage,
              let rawString = QRCodeService.extractString(from: image),
              let url = URL(string: rawString),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme) else {
            alertMessage = AppLanguage.useSimplifiedChinese ? "未识别到二维码" : "QR code not recognized"
            return
        }
        onImportURL(rawString)
        dismiss()
    }

    private func loadLatestPhoto() async {
        await MainActor.run {
            isLoadingLatestPhoto = true
        }
        defer {
            Task { @MainActor in
                isLoadingLatestPhoto = false
            }
        }

        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if status == .notDetermined {
            let _ = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        }
        let authorizedStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard authorizedStatus == .authorized || authorizedStatus == .limited else {
            await MainActor.run {
                latestImage = nil
            }
            return
        }

        let options = PHFetchOptions()
        options.predicate = NSPredicate(
            format: "mediaType == %d",
            PHAssetMediaType.image.rawValue
        )
        options.sortDescriptors = [
            NSSortDescriptor(key: #keyPath(PHAsset.creationDate), ascending: false),
            NSSortDescriptor(key: #keyPath(PHAsset.modificationDate), ascending: false)
        ]
        options.fetchLimit = 1
        let result = PHAsset.fetchAssets(with: options)
        guard let asset = result.firstObject else {
            await MainActor.run {
                latestImage = nil
            }
            return
        }

        let manager = PHImageManager.default()
        let requestOptions = PHImageRequestOptions()
        requestOptions.deliveryMode = .highQualityFormat
        requestOptions.resizeMode = .exact
        requestOptions.isSynchronous = false
        requestOptions.isNetworkAccessAllowed = true

        manager.requestImage(
            for: asset,
            targetSize: CGSize(width: 300, height: 300),
            contentMode: .aspectFill,
            options: requestOptions
        ) { image, info in
            let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
            guard !isDegraded else { return }
            Task { @MainActor in
                latestImage = image
            }
        }
    }
}

#Preview {
    ImportSubscriptionView(
        onImportURL: { _ in },
        onImportFromClipboard: {}
    )
}
