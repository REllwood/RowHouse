import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import RowHouseCore
import SwiftUI

/// Edits a barcode's text and symbology, and shows the barcode itself outside forms.
struct BarcodeEditor: View {
    @Binding var value: JSONValue
    let style: EditorStyle
    var initialText: String?

    var body: some View {
        let barcode = BarcodeValue(json: value)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                CommitTextField(text: barcode?.text ?? "", prompt: "Barcode text or number", initialText: initialText, commitOnChange: style == .form) { text in
                    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    let updated: JSONValue = trimmed.isEmpty ? .null : BarcodeValue(text: trimmed, type: BarcodeValue(json: value)?.type).json
                    if updated != value { value = updated }
                }
                Picker("Type", selection: Binding(get: { barcode?.type ?? "" }, set: { type in
                    guard var current = BarcodeValue(json: value) else { return }
                    current.type = type.isEmpty ? nil : type
                    value = current.json
                })) {
                    Text("Automatic").tag("")
                    ForEach(BarcodeValue.knownTypes, id: \.id) { Text($0.name).tag($0.id) }
                    if let custom = barcode?.type, !BarcodeValue.knownTypes.contains(where: { $0.id == custom }) {
                        Text(BarcodeValue.displayName(forType: custom)).tag(custom)
                    }
                }
                .labelsHidden()
                .frame(width: 120)
                .disabled(barcode == nil)
                .help("Barcode type")
            }
            if style != .form, let barcode {
                BarcodeImageView(barcode: barcode)
            }
        }
    }
}

/// The rendered barcode (a QR code for the "qr" type, Code 128 otherwise) with its text beneath.
struct BarcodeImageView: View {
    let barcode: BarcodeValue

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let image = BarcodeRenderer.cgImage(for: barcode) {
                Image(decorative: image, scale: 1)
                    .interpolation(.none)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: barcode.isQRCode ? 150 : 280, maxHeight: barcode.isQRCode ? 150 : 80)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.white))
                    .accessibilityLabel("Barcode for \(barcode.text)")
            } else {
                Label("This text can't be drawn as a Code 128 barcode. Choose QR code to show it.", systemImage: "barcode")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(barcode.text)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }
}

enum BarcodeRenderer {
    private static let context = CIContext(options: [.useSoftwareRenderer: false])

    /// A pixel-exact image (one pixel per module); draw it scaled up without interpolation.
    static func cgImage(for barcode: BarcodeValue) -> CGImage? {
        let output: CIImage?
        if barcode.isQRCode {
            let filter = CIFilter.qrCodeGenerator()
            filter.message = Data(barcode.text.utf8)
            filter.correctionLevel = "M"
            output = filter.outputImage
        } else {
            guard let data = barcode.text.data(using: .ascii) else { return nil }
            let filter = CIFilter.code128BarcodeGenerator()
            filter.message = data
            filter.quietSpace = 7
            output = filter.outputImage
        }
        guard let output, !output.extent.isInfinite, !output.extent.isEmpty else { return nil }
        return context.createCGImage(output, from: output.extent)
    }
}
