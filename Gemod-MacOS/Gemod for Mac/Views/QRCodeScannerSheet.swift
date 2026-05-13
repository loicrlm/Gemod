import AVFoundation
import SwiftUI

@available(macOS 13.0, *)
struct QRCodeScannerSheet: View {
    @ObservedObject var viewModel: AppViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var scannedCode: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Scan QR")
                .font(.title3)
                .fontWeight(.semibold)

            QRCodeScannerRepresentable(scannedCode: $scannedCode)
                .frame(height: 320)
                .clipShape(RoundedRectangle(cornerRadius: 12))

            Text(scannedCode ?? "Place the QR code in the frame. It will import automatically after recognition.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Close") {
                    Task { @MainActor in
                        viewModel.isScannerPresented = false
                        dismiss()
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 520, height: 420)
        .onChange(of: scannedCode) { code in
            guard let code, !code.isEmpty else { return }
            Task { @MainActor in
                viewModel.importFromScannedCode(code)
                dismiss()
            }
        }
    }
}

@available(macOS 13.0, *)
struct QRCodeScannerRepresentable: NSViewRepresentable {
    @Binding var scannedCode: String?

    func makeCoordinator() -> Coordinator {
        Coordinator(scannedCode: $scannedCode)
    }

    func makeNSView(context: Context) -> CameraPreviewView {
        let view = CameraPreviewView()
        context.coordinator.start(on: view)
        return view
    }

    func updateNSView(_ nsView: CameraPreviewView, context: Context) {
    }

    static func dismantleNSView(_ nsView: CameraPreviewView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class Coordinator: NSObject, AVCaptureMetadataOutputObjectsDelegate {
        @Binding private var scannedCode: String?
        private let session = AVCaptureSession()
        private weak var previewView: CameraPreviewView?

        init(scannedCode: Binding<String?>) {
            self._scannedCode = scannedCode
        }

        func start(on view: CameraPreviewView) {
            previewView = view
            Task {
                let status = AVCaptureDevice.authorizationStatus(for: .video)
                if status == .notDetermined {
                    _ = await AVCaptureDevice.requestAccess(for: .video)
                }
                await MainActor.run {
                    configureSessionIfNeeded()
                }
            }
        }

        func stop() {
            session.stopRunning()
        }

        private func configureSessionIfNeeded() {
            guard session.inputs.isEmpty else {
                if !session.isRunning {
                    session.startRunning()
                }
                return
            }

            guard let device = AVCaptureDevice.default(for: .video),
                  let input = try? AVCaptureDeviceInput(device: device),
                  session.canAddInput(input) else {
                return
            }

            let output = AVCaptureMetadataOutput()
            guard session.canAddOutput(output) else { return }

            session.beginConfiguration()
            session.addInput(input)
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: .main)
            let availableTypes = output.availableMetadataObjectTypes
            guard availableTypes.contains(.qr) else {
                session.commitConfiguration()
                return
            }
            output.metadataObjectTypes = [.qr]
            session.commitConfiguration()

            previewView?.previewLayer.session = session
            previewView?.previewLayer.videoGravity = .resizeAspectFill
            session.startRunning()
        }

        func metadataOutput(
            _ output: AVCaptureMetadataOutput,
            didOutput metadataObjects: [AVMetadataObject],
            from connection: AVCaptureConnection
        ) {
            guard scannedCode == nil,
                  let value = (metadataObjects.first as? AVMetadataMachineReadableCodeObject)?.stringValue else {
                return
            }
            scannedCode = value
            session.stopRunning()
        }
    }
}

@available(macOS 13.0, *)
final class CameraPreviewView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
    }

    override func makeBackingLayer() -> CALayer {
        previewLayer
    }

    var previewLayer: AVCaptureVideoPreviewLayer {
        layer as? AVCaptureVideoPreviewLayer ?? AVCaptureVideoPreviewLayer()
    }
}
