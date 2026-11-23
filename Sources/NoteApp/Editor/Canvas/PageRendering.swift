#if canImport(UIKit)
import CoreGraphics
import InkBridge
import NoteKit
import UIKit

enum PDFSupport {
    static func document(at url: URL) -> CGPDFDocument? { CGPDFDocument(url as CFURL) }

    /// Page size in points as displayed (crop box, rotation applied).
    static func pageSize(_ page: CGPDFPage) -> PageSize {
        let box = page.getBoxRect(.cropBox)
        let rotation = ((Int(page.rotationAngle) % 360) + 360) % 360
        if rotation == 90 || rotation == 270 {
            return PageSize(width: Double(box.height), height: Double(box.width))
        }
        return PageSize(width: Double(box.width), height: Double(box.height))
    }

    static func pageSizes(of url: URL) -> [PageSize] {
        guard let doc = document(at: url), doc.numberOfPages > 0 else { return [] }
        return (1...doc.numberOfPages).compactMap { doc.page(at: $0).map(pageSize) }
    }

    /// Draws `page` into (0, 0, size) of a y-down context whose units are page points.
    static func draw(_ page: CGPDFPage, size: PageSize, in ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: 0, y: CGFloat(size.height))
        ctx.scaleBy(x: 1, y: -1)
        let rect = CGRect(x: 0, y: 0, width: size.width, height: size.height)
        ctx.concatenate(page.getDrawingTransform(.cropBox, rect: rect, rotate: 0, preserveAspectRatio: true))
        ctx.clip(to: page.getBoxRect(.cropBox))
        ctx.interpolationQuality = .high
        ctx.setRenderingIntent(.defaultIntent)
        ctx.drawPDFPage(page)
        ctx.restoreGState()
    }
}

/// Paper templates, drawn in page units (y down).
enum PaperRenderer {
    static func color(_ paper: PaperStyle) -> UIColor { UIColor(hex: paper.color.hex) }

    static func draw(_ paper: PaperStyle, size: PageSize, in ctx: CGContext, clip: CGRect? = nil) {
        let w = CGFloat(size.width), h = CGFloat(size.height)
        let area = clip ?? CGRect(x: 0, y: 0, width: w, height: h)
        let s = CGFloat(paper.effectiveSpacing)
        let line: CGFloat = 0.6
        ctx.saveGState()
        ctx.setLineWidth(line)
        switch paper.template {
        case .blank:
            break
        case .ruled, .narrowRuled:
            let top = max(s * 3, 64)
            ctx.setStrokeColor(NoteTheme.paperRule.cgColor)
            horizontalLines(ctx, from: top, to: h - s * 0.5, step: s, width: w, area: area)
            ctx.strokePath()
            let marginX = (w * 0.107).rounded()
            if area.minX <= marginX && area.maxX >= marginX {
                ctx.setStrokeColor(NoteTheme.paperMargin.cgColor)
                ctx.move(to: CGPoint(x: marginX, y: 0))
                ctx.addLine(to: CGPoint(x: marginX, y: h))
                ctx.strokePath()
            }
        case .grid:
            ctx.setStrokeColor(NoteTheme.paperRule.cgColor)
            horizontalLines(ctx, from: s, to: h, step: s, width: w, area: area)
            var x = s
            while x < w {
                if x >= area.minX - line && x <= area.maxX + line {
                    ctx.move(to: CGPoint(x: x, y: max(0, area.minY)))
                    ctx.addLine(to: CGPoint(x: x, y: min(h, area.maxY)))
                }
                x += s
            }
            ctx.strokePath()
        case .dotted:
            ctx.setFillColor(NoteTheme.paperDot.cgColor)
            let r: CGFloat = 0.9
            var y = s
            while y < h {
                if y >= area.minY - r && y <= area.maxY + r {
                    var x = s
                    while x < w {
                        if x >= area.minX - r && x <= area.maxX + r {
                            ctx.addEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
                        }
                        x += s
                    }
                }
                y += s
            }
            ctx.fillPath()
        case .cornell:
            let top = max(s * 3, 64)
            let summaryY = (h * 0.78).rounded()
            let cueX = (w * 0.3).rounded()
            ctx.setStrokeColor(NoteTheme.paperRule.cgColor)
            horizontalLines(ctx, from: top, to: summaryY, step: s, width: w, area: area)
            ctx.strokePath()
            ctx.setStrokeColor(NoteTheme.paperMargin.cgColor)
            ctx.setLineWidth(1)
            ctx.move(to: CGPoint(x: cueX, y: top - s))
            ctx.addLine(to: CGPoint(x: cueX, y: summaryY))
            ctx.move(to: CGPoint(x: 0, y: summaryY))
            ctx.addLine(to: CGPoint(x: w, y: summaryY))
            ctx.move(to: CGPoint(x: 0, y: top - s))
            ctx.addLine(to: CGPoint(x: w, y: top - s))
            ctx.strokePath()
        case .music:
            ctx.setStrokeColor(NoteTheme.paperRuleStrong.cgColor)
            let staffGap = s * 7
            var y: CGFloat = 72
            while y + s * 4 < h - 36 {
                for i in 0..<5 {
                    let ly = y + CGFloat(i) * s
                    if ly >= area.minY - 1 && ly <= area.maxY + 1 {
                        ctx.move(to: CGPoint(x: 36, y: ly))
                        ctx.addLine(to: CGPoint(x: w - 36, y: ly))
                    }
                }
                y += s * 4 + staffGap
            }
            ctx.strokePath()
        }
        ctx.restoreGState()
    }

    private static func horizontalLines(_ ctx: CGContext, from start: CGFloat, to end: CGFloat, step: CGFloat,
                                        width: CGFloat, area: CGRect) {
        guard step > 0 else { return }
        var y = start
        while y <= end {
            if y >= area.minY - 1 && y <= area.maxY + 1 {
                ctx.move(to: CGPoint(x: max(0, area.minX), y: y))
                ctx.addLine(to: CGPoint(x: min(width, area.maxX), y: y))
            }
            y += step
        }
    }
}

/// Premultiplied RGBA8 bitmap contexts in the byte order InkEngine expects.
enum Bitmaps {
    static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

    static func context(width: Int, height: Int) -> CGContext? {
        CGContext(data: nil, width: max(width, 1), height: max(height, 1), bitsPerComponent: 8,
                  bytesPerRow: max(width, 1) * 4, space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
    }

    /// Switches a bitmap context (y up) to y-down page units for a region that
    /// starts at pixel `origin` of a page rendered at `scale` pixels per unit.
    static func enterPageSpace(_ ctx: CGContext, pixelHeight: Int, origin: CGPoint, scale: CGFloat) {
        ctx.translateBy(x: 0, y: CGFloat(pixelHeight))
        ctx.scaleBy(x: 1, y: -1)
        ctx.translateBy(x: -origin.x, y: -origin.y)
        ctx.scaleBy(x: scale, y: scale)
    }
}

/// Renders whole pages to images (thumbnails, previews, sharing).
enum PageImageRenderer {
    /// Paper or PDF background for the region `origin`… of a page at `scale`, into a fresh context.
    static func drawBackground(page: NotebookPage, pdfPage: CGPDFPage?, in ctx: CGContext, pixelWidth: Int,
                               pixelHeight: Int, origin: CGPoint, scale: CGFloat) {
        ctx.saveGState()
        ctx.setFillColor((pdfPage != nil ? UIColor.white : PaperRenderer.color(page.paper)).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        Bitmaps.enterPageSpace(ctx, pixelHeight: pixelHeight, origin: origin, scale: scale)
        let clip = CGRect(x: origin.x / scale, y: origin.y / scale,
                          width: CGFloat(pixelWidth) / scale, height: CGFloat(pixelHeight) / scale)
        if let pdfPage {
            PDFSupport.draw(pdfPage, size: page.size, in: ctx)
        } else {
            PaperRenderer.draw(page.paper, size: page.size, in: ctx, clip: clip)
        }
        ctx.restoreGState()
    }

    static func image(page: NotebookPage, ink: InkPage?, pdf: CGPDFDocument?, package: NotebookPackage?,
                      pixelWidth: Int) -> CGImage? {
        let scale = CGFloat(pixelWidth) / CGFloat(page.size.width)
        let pixelHeight = Int((CGFloat(page.size.height) * scale).rounded())
        guard let ctx = Bitmaps.context(width: pixelWidth, height: pixelHeight) else { return nil }
        let pdfPage = page.background.pdfPageIndex.flatMap { pdf?.page(at: $0 + 1) }
        drawBackground(page: page, pdfPage: pdfPage, in: ctx, pixelWidth: pixelWidth, pixelHeight: pixelHeight,
                       origin: .zero, scale: scale)
        if let ink, let data = ctx.data {
            ink.renderOver(data, width: pixelWidth, height: pixelHeight, bytesPerRow: ctx.bytesPerRow,
                           scale: Float(scale), offsetX: 0, offsetY: 0)
        }
        if !page.elements.isEmpty {
            ctx.saveGState()
            Bitmaps.enterPageSpace(ctx, pixelHeight: pixelHeight, origin: .zero, scale: scale)
            ElementDrawing.draw(page.elements, package: package, in: ctx)
            ctx.restoreGState()
        }
        return ctx.makeImage()
    }
}

/// Text boxes and images drawn with Core Graphics (thumbnails, export).
enum ElementDrawing {
    static func textAttributes(_ element: PageElement) -> [NSAttributedString.Key: Any] {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byWordWrapping
        return [
            .font: UIFont.systemFont(ofSize: CGFloat(element.fontSize ?? 16)),
            .foregroundColor: UIColor(hex: element.colorHex ?? "#1C1C1E"),
            .paragraphStyle: style,
        ]
    }

    /// `ctx` is y-down in page units.
    static func draw(_ elements: [PageElement], package: NotebookPackage?, in ctx: CGContext) {
        UIGraphicsPushContext(ctx)
        defer { UIGraphicsPopContext() }
        for element in elements {
            let rect = CGRect(x: element.frame.x, y: element.frame.y, width: element.frame.width,
                              height: element.frame.height)
            switch element.kind {
            case .text:
                ((element.text ?? "") as NSString).draw(with: rect, options: [.usesLineFragmentOrigin],
                                                        attributes: textAttributes(element), context: nil)
            case .image:
                if let name = element.asset, let package, let image = UIImage(contentsOfFile: package.assetURL(name).path) {
                    image.draw(in: rect)
                }
            }
        }
    }
}

/// Builds a vector PDF of a notebook: PDF/paper backgrounds, ink outlines, text and images.
enum NotebookPDFExporter {
    static func export(document: NotebookDocument, package: NotebookPackage, inkPages: [UUID: InkPage],
                       to url: URL) throws {
        let pdf = document.pdf.flatMap { PDFSupport.document(at: package.assetURL($0.file)) }
        let first = document.pages.first?.size ?? PageSizePreset.a4.size
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: first.width, height: first.height))
        try renderer.writePDF(to: url) { context in
            for page in document.pages {
                let bounds = CGRect(x: 0, y: 0, width: page.size.width, height: page.size.height)
                context.beginPage(withBounds: bounds, pageInfo: [:])
                let ctx = context.cgContext
                if let index = page.background.pdfPageIndex, let pdfPage = pdf?.page(at: index + 1) {
                    PDFSupport.draw(pdfPage, size: page.size, in: ctx)
                } else {
                    ctx.setFillColor(PaperRenderer.color(page.paper).cgColor)
                    ctx.fill(bounds)
                    PaperRenderer.draw(page.paper, size: page.size, in: ctx)
                }
                if let inkPage = inkPages[page.id] {
                    drawOutlines(InkOutlineParser.parse(inkPage.exportSVG()), in: ctx)
                }
                ElementDrawing.draw(page.elements, package: package, in: ctx)
            }
        }
    }

    static func drawOutlines(_ outlines: [InkOutline], in ctx: CGContext) {
        for outline in outlines {
            guard let first = outline.points.first else { continue }
            let path = CGMutablePath()
            path.move(to: CGPoint(x: first.x, y: first.y))
            for p in outline.points.dropFirst() { path.addLine(to: CGPoint(x: p.x, y: p.y)) }
            path.closeSubpath()
            let color = UIColor(hex: outline.colorHex).cgColor
            ctx.saveGState()
            ctx.setAlpha(CGFloat(outline.opacity))
            if outline.multiply { ctx.setBlendMode(.multiply) }
            if outline.opacity < 1 || outline.strokeWidth > 0 {
                // Fill and stroke as one group so overlapping parts don't double up.
                ctx.beginTransparencyLayer(auxiliaryInfo: nil)
                ctx.setAlpha(1)
            }
            ctx.setFillColor(color)
            ctx.addPath(path)
            ctx.fillPath(using: .winding)
            if outline.strokeWidth > 0 {
                ctx.setStrokeColor(color)
                ctx.setLineWidth(CGFloat(outline.strokeWidth))
                ctx.setLineJoin(.round)
                ctx.setLineCap(.round)
                ctx.addPath(path)
                ctx.strokePath()
            }
            if outline.opacity < 1 || outline.strokeWidth > 0 { ctx.endTransparencyLayer() }
            ctx.restoreGState()
        }
    }
}
#endif
