//
//  QRImage.swift
//  Clrc
//

import AppKit
import CoreImage.CIFilterBuiltins

func qrImage(from string: String) -> NSImage? {
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(string.utf8)
    filter.correctionLevel = "M"
    guard let ci = filter.outputImage?.transformed(by: .init(scaleX: 8, y: 8)) else { return nil }
    let rep = NSCIImageRep(ciImage: ci)
    let img = NSImage(size: rep.size)
    img.addRepresentation(rep)
    return img
}
