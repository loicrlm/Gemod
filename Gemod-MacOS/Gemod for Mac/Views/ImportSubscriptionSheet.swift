import AVFoundation
import SwiftUI

struct ImportSubscriptionSheet: View {
    @ObservedObject var viewModel: AppViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Import Subscription")
                    .font(.title2)
                    .fontWeight(.semibold)
                Spacer()
                Button {
                    Task { @MainActor in
                        viewModel.isImportSheetPresented = false
                        dismiss()
                    }
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .keyboardShortcut(.cancelAction)
            }

            TextField("https://example.com/subscription", text: $viewModel.importURLText)
                .textFieldStyle(.roundedBorder)

            HStack {
                Button("Import URL") {
                    viewModel.importFromManualURL()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(viewModel.isImporting)

                Button("Scan QR") {
                    if #available(macOS 13.0, *) {
                        guard AVCaptureDevice.default(for: .video) != nil else {
                            Task { @MainActor in
                                viewModel.alertMessage = "No camera is available on this Mac."
                            }
                            return
                        }
                        Task { @MainActor in
                            viewModel.isScannerPresented = true
                        }
                    } else {
                        Task { @MainActor in
                            viewModel.alertMessage = "QR scanning requires macOS 13 or later."
                        }
                    }
                }
                .disabled(viewModel.isImporting)
            }

            if viewModel.isImporting {
                ProgressView("Importing subscription...")
                    .controlSize(.small)
            }

            Text("Tip: Clicking + at the bottom-left tries clipboard import first. Only one subscription is kept; importing a new one fully replaces the previous subscription and nodes.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Spacer()
        }
        .padding(20)
        .frame(width: 520, height: 210)
        .sheet(isPresented: $viewModel.isScannerPresented) {
            if #available(macOS 13.0, *) {
                QRCodeScannerSheet(viewModel: viewModel)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "qrcode.viewfinder")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text("QR scanning requires macOS 13 or later.")
                        .font(.callout)
                    Button("Close") {
                        Task { @MainActor in
                            viewModel.isScannerPresented = false
                            dismiss()
                        }
                    }
                }
                .frame(width: 360, height: 180)
                .padding(16)
            }
        }
        .onChange(of: viewModel.isImportSheetPresented) { presented in
            if !presented {
                Task { @MainActor in
                    dismiss()
                }
            }
        }
    }
}
