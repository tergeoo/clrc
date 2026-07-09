import SwiftUI
import VisionKit
import Vision
import ClrcCore

/// Full-screen camera scanner that reads a `clrc://pair` QR code and returns the
/// decoded relay URL + password. Invalid / non-clrc codes are ignored so the
/// user can keep the camera pointed until a valid pairing code is found.
struct ScanToPairView: View {
    var onScan: (PairInfo) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
                    Scanner { info in
                        onScan(info)
                        dismiss()
                    }
                    .ignoresSafeArea(edges: .bottom)
                } else {
                    ContentUnavailableView(
                        "Camera unavailable",
                        systemImage: "camera.fill",
                        description: Text("Scanning needs a device camera. Enter the relay URL and password manually.")
                    )
                }
            }
            .navigationTitle("Scan to pair")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

// MARK: - VisionKit bridge

private struct Scanner: UIViewControllerRepresentable {
    var onScan: (PairInfo) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let vc = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            isHighFrameRateTrackingEnabled: false,
            isPinchToZoomEnabled: true,
            isGuidanceEnabled: true,
            isHighlightingEnabled: true
        )
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: DataScannerViewController, context: Context) {
        try? vc.startScanning()
    }

    func makeCoordinator() -> Coordinator { Coordinator(onScan: onScan) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        private let onScan: (PairInfo) -> Void
        private var handled = false

        init(onScan: @escaping (PairInfo) -> Void) { self.onScan = onScan }

        func dataScanner(_ scanner: DataScannerViewController,
                         didAdd addedItems: [RecognizedItem],
                         allItems: [RecognizedItem]) {
            handle(addedItems, scanner)
        }

        func dataScanner(_ scanner: DataScannerViewController,
                         didTapOn item: RecognizedItem) {
            handle([item], scanner)
        }

        private func handle(_ items: [RecognizedItem], _ scanner: DataScannerViewController) {
            guard !handled else { return }
            let now = Int64(Date().timeIntervalSince1970)
            for item in items {
                guard case let .barcode(barcode) = item,
                      let string = barcode.payloadStringValue,
                      let info = try? PairLink.decode(string, now: now) else { continue }
                handled = true
                scanner.stopScanning()
                onScan(info)
                return
            }
        }
    }
}
