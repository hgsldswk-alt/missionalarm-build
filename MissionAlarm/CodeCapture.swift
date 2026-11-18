import AVFoundation
import SwiftUI
import Vision
import VisionKit

struct CodeCapture: View {
    @Environment(\.scenePhase) private var phase
    @State private var authorized: Bool?
    @State private var failed = false
    let onCode: (ScanCode) -> Void

    var body: some View {
        Group {
            if authorized == true && !failed && phase != .background {
                ScannerController(onCode: onCode, onFailure: { failed = true })
            } else {
                VStack(spacing: 14) {
                    if authorized == nil {
                        ProgressView()
                    } else {
                        Image(systemName: "qrcode.viewfinder").font(.largeTitle)
                        Text(L.t("摄像头不可用")).multilineTextAlignment(.center)
                        if AVCaptureDevice.authorizationStatus(for: .video) == .denied {
                            Button(L.t("去系统设置"), action: openSystemSettings).buttonStyle(.bordered)
                        }
                    }
                }
                .foregroundStyle(Palette.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Palette.card)
            }
        }
        .frame(minHeight: 190)
        .clipShape(RoundedRectangle(cornerRadius: 18))
        .task { await checkAccess() }
        .onChange(of: phase) { _, newPhase in
            if newPhase == .active {
                failed = false
                Task { await checkAccess() }
            }
        }
    }

    private func checkAccess() async {
        guard DataScannerViewController.isSupported else { authorized = false; return }
        let allowed: Bool
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: allowed = true
        case .notDetermined: allowed = await AVCaptureDevice.requestAccess(for: .video)
        default: allowed = false
        }
        let available = allowed && DataScannerViewController.isAvailable
        if authorized != available {
            failed = false
            authorized = available
        }
    }
}

private struct ScannerController: UIViewControllerRepresentable {
    let onCode: (ScanCode) -> Void
    let onFailure: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode()], qualityLevel: .balanced, recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false, isPinchToZoomEnabled: true,
            isGuidanceEnabled: true, isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        let coordinator = context.coordinator
        coordinator.onCode = onCode
        coordinator.onFailure = onFailure
        if !coordinator.started {
            coordinator.started = true
            Task { @MainActor [weak scanner, weak coordinator] in
                guard let scanner, let coordinator, coordinator.started else { return }
                do { try scanner.startScanning() }
                catch { coordinator.onFailure?() }
            }
        }
    }

    static func dismantleUIViewController(_ scanner: DataScannerViewController, coordinator: Coordinator) {
        coordinator.started = false
        scanner.stopScanning()
        scanner.delegate = nil
    }

    @MainActor
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        var onCode: ((ScanCode) -> Void)?
        var onFailure: (() -> Void)?
        var started = false

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem],
                         allItems: [RecognizedItem]) {
            for item in addedItems {
                if case .barcode(let barcode) = item, let value = barcode.payloadStringValue, !value.isEmpty {
                    onCode?(ScanCode(type: barcode.observation.symbology.rawValue, value: value))
                }
            }
        }

        func dataScanner(_ dataScanner: DataScannerViewController,
                         becameUnavailableWithError error: DataScannerViewController.ScanningUnavailable) {
            onFailure?()
        }
    }
}
