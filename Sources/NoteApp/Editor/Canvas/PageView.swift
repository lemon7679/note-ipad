#if canImport(UIKit)
import InkBridge
import NoteKit
import UIKit

private struct TileKey: Hashable {
    let col: Int
    let row: Int
}

private final class Tile {
    let layer: CALayer
    /// Cached paper/PDF background (PDF pages only; templates are cheap to redraw).
    var background: CGImage?
    var valid = false
    /// Bumped whenever the tile's content becomes outdated; a worker result is used only
    /// if it was started for the current epoch.
    var epoch = 0
    /// Epoch a worker is rendering right now, if any.
    var renderingEpoch: Int?

    var isRendering: Bool { renderingEpoch == epoch }

    init() {
        layer = CALayer()
        layer.actions = ["contents": NSNull(), "position": NSNull(), "bounds": NSNull(), "frame": NSNull()]
        layer.contentsGravity = .resize
    }
}

/// One page on the canvas.
///
/// Rendering: a low-resolution preview of the whole page sits underneath
/// 512-px tiles rendered at the current zoom level (paper/PDF + ink). Tiles
/// for scrolling and zooming, and the preview, are rendered on worker threads
/// from ink snapshots (`TileRenderQueue`), nearest to the middle of the screen
/// first, so the main thread never waits for them. While a stroke is drawn,
/// only the overlay tiles it touches are redrawn each frame
/// (`StrokeBuilder.renderOver`); on pen-up (and for erasing / undo) the
/// affected ink tiles are re-rendered in the same frame and the overlay is
/// dropped, so nothing flickers. Old tiles stay visible after a zoom until
/// the sharper set is ready.
final class PageView: UIView {
    static let tilePixels = 512

    let pageID: UUID
    private(set) var page: NotebookPage
    let ink: InkPage
    let pdfPage: CGPDFPage?
    let package: NotebookPackage
    /// Page-view points per page unit (layout scale, before zoom).
    private(set) var pointsPerUnit: CGFloat
    var screenScale: CGFloat = 2

    private let previewLayer = CALayer()
    private let tileContainer = CALayer()
    private var staleContainer: CALayer?
    private let overlayContainer = CALayer()
    private let decorationContainer = CALayer()
    private let lassoLayer = CAShapeLayer()
    private let selectionLayer = CAShapeLayer()
    private let handleLayer = CAShapeLayer()
    private let floatingLayer = CALayer()
    private let highlightLayer = CALayer()
    private let eraserCursor = CAShapeLayer()

    private(set) var renderScale: CGFloat = 0
    private var tiles: [TileKey: Tile] = [:]
    private var overlayTiles: [TileKey: CALayer] = [:]
    private var pending: Set<TileKey> = []
    private var visibleRect: CGRect = .null
    private var previewValid = false
    private var previewDirtyAt: CFTimeInterval?
    private var previewEpoch = 0
    private var previewRendering = false
    /// Worker jobs started by this page that have not come back yet.
    private var inFlight = 0
    private var elementViews: [UUID: ElementView] = [:]
    var elementsInteractive = false {
        didSet { elementViews.values.forEach { $0.isUserInteractionEnabled = elementsInteractive } }
    }
    var textEditingEnabled = false {
        didSet { elementViews.values.forEach { $0.textEditable = textEditingEnabled } }
    }
    var onElementChange: ((PageElement) -> Void)?
    var onElementDelete: ((UUID) -> Void)?

    init(page: NotebookPage, ink: InkPage, pdfPage: CGPDFPage?, package: NotebookPackage, pointsPerUnit: CGFloat) {
        self.pageID = page.id
        self.page = page
        self.ink = ink
        self.pdfPage = pdfPage
        self.package = package
        self.pointsPerUnit = pointsPerUnit
        super.init(frame: .zero)
        backgroundColor = pdfPage != nil ? .white : PaperRenderer.color(page.paper)
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.10
        layer.shadowRadius = 6
        layer.shadowOffset = CGSize(width: 0, height: 2)
        isMultipleTouchEnabled = true

        let noAnimation: [String: CAAction] = ["contents": NSNull(), "position": NSNull(), "bounds": NSNull(),
                                               "frame": NSNull(), "path": NSNull(), "opacity": NSNull(),
                                               "transform": NSNull(), "hidden": NSNull()]
        for l in [previewLayer, tileContainer, overlayContainer, decorationContainer, lassoLayer, selectionLayer,
                  handleLayer, floatingLayer, highlightLayer, eraserCursor] {
            l.actions = noAnimation
        }
        previewLayer.contentsGravity = .resize
        previewLayer.magnificationFilter = .linear
        layer.addSublayer(previewLayer)
        layer.addSublayer(tileContainer)
        layer.addSublayer(overlayContainer)
        layer.addSublayer(decorationContainer)

        highlightLayer.backgroundColor = UIColor.systemYellow.withAlphaComponent(0.35).cgColor
        highlightLayer.isHidden = true
        decorationContainer.addSublayer(highlightLayer)
        decorationContainer.addSublayer(floatingLayer)

        lassoLayer.fillColor = NoteTheme.accentUI.withAlphaComponent(0.06).cgColor
        lassoLayer.strokeColor = NoteTheme.accentUI.cgColor
        lassoLayer.lineDashPattern = [6, 4]
        decorationContainer.addSublayer(lassoLayer)

        selectionLayer.fillColor = UIColor.clear.cgColor
        selectionLayer.strokeColor = NoteTheme.accentUI.cgColor
        selectionLayer.lineDashPattern = [6, 4]
        decorationContainer.addSublayer(selectionLayer)
        handleLayer.fillColor = UIColor.white.cgColor
        handleLayer.strokeColor = NoteTheme.accentUI.cgColor
        decorationContainer.addSublayer(handleLayer)

        eraserCursor.fillColor = UIColor.white.withAlphaComponent(0.4).cgColor
        eraserCursor.strokeColor = UIColor.darkGray.cgColor
        eraserCursor.isHidden = true
        decorationContainer.addSublayer(eraserCursor)
        syncElements(page.elements)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        previewLayer.frame = bounds
        tileContainer.frame = bounds
        staleContainer?.frame = bounds
        overlayContainer.frame = bounds
        decorationContainer.frame = bounds
        lassoLayer.frame = bounds
        selectionLayer.frame = bounds
        handleLayer.frame = bounds
        eraserCursor.frame = bounds
        layer.shadowPath = UIBezierPath(rect: bounds).cgPath
        CATransaction.commit()
    }

    // MARK: Geometry

    func pagePoint(_ viewPoint: CGPoint) -> CGPoint {
        CGPoint(x: viewPoint.x / pointsPerUnit, y: viewPoint.y / pointsPerUnit)
    }

    func viewRect(_ pageRect: CGRect) -> CGRect {
        CGRect(x: pageRect.minX * pointsPerUnit, y: pageRect.minY * pointsPerUnit,
               width: pageRect.width * pointsPerUnit, height: pageRect.height * pointsPerUnit)
    }

    private var pixelSize: (w: Int, h: Int) {
        (Int((CGFloat(page.size.width) * renderScale).rounded(.up)),
         Int((CGFloat(page.size.height) * renderScale).rounded(.up)))
    }

    private func pixelRect(_ key: TileKey) -> CGRect {
        let (w, h) = pixelSize
        let t = Self.tilePixels
        let x = key.col * t, y = key.row * t
        return CGRect(x: x, y: y, width: max(0, min(t, w - x)), height: max(0, min(t, h - y)))
    }

    private func layerFrame(_ px: CGRect) -> CGRect {
        let f = pointsPerUnit / renderScale
        return CGRect(x: px.minX * f, y: px.minY * f, width: px.width * f, height: px.height * f)
    }

    private func keys(intersecting pageRect: CGRect) -> [TileKey] {
        guard renderScale > 0, !pageRect.isNull, !pageRect.isEmpty else { return [] }
        let (w, h) = pixelSize
        let t = CGFloat(Self.tilePixels)
        let px = CGRect(x: pageRect.minX * renderScale, y: pageRect.minY * renderScale,
                        width: pageRect.width * renderScale, height: pageRect.height * renderScale)
            .intersection(CGRect(x: 0, y: 0, width: w, height: h))
        guard !px.isNull, !px.isEmpty else { return [] }
        let c0 = Int(floor(px.minX / t)), c1 = Int(floor((px.maxX - 0.001) / t))
        let r0 = Int(floor(px.minY / t)), r1 = Int(floor((px.maxY - 0.001) / t))
        guard c0 <= c1, r0 <= r1 else { return [] }
        var out: [TileKey] = []
        for r in r0...r1 { for c in c0...c1 { out.append(TileKey(col: c, row: r)) } }
        return out
    }

    // MARK: Layout & visibility

    func setPointsPerUnit(_ value: CGFloat) {
        guard abs(value - pointsPerUnit) > 0.0001 else { return }
        pointsPerUnit = value
        renderScale = 0   // forces a new tile set
        dropAllTiles(keepStale: false)
        previewValid = false
        previewEpoch += 1
        for view in elementViews.values { view.pointsPerUnit = value }
    }

    /// `pageRect` is the visible part of the page (page units), `.null` when off-screen.
    func setVisible(_ pageRect: CGRect, renderScale newScale: CGFloat) {
        visibleRect = pageRect
        if abs(newScale - renderScale) > renderScale * 0.01 {
            // New zoom: keep the old tiles on screen until the sharp ones are ready.
            dropAllTiles(keepStale: renderScale > 0)
            renderScale = newScale
        }
        guard !pageRect.isNull else {
            dropAllTiles(keepStale: false)
            return
        }
        let margin = CGFloat(Self.tilePixels) / 2 / max(renderScale, 0.0001)
        let needed = Set(keys(intersecting: pageRect.insetBy(dx: -margin, dy: -margin)))
        for (key, tile) in tiles where !needed.contains(key) {
            tile.layer.removeFromSuperlayer()
            tiles[key] = nil
        }
        pending = pending.intersection(needed)
        for key in needed {
            if let tile = tiles[key], tile.valid || tile.isRendering { continue }
            pending.insert(key)
        }
    }

    private func dropAllTiles(keepStale: Bool) {
        staleContainer?.removeFromSuperlayer()
        staleContainer = nil
        if keepStale, !tiles.isEmpty {
            let stale = CALayer()
            stale.actions = ["sublayers": NSNull()]
            stale.frame = bounds
            for tile in tiles.values where tile.valid { stale.addSublayer(tile.layer) }
            layer.insertSublayer(stale, above: previewLayer)
            staleContainer = stale
        } else {
            for tile in tiles.values { tile.layer.removeFromSuperlayer() }
        }
        tiles.removeAll()
        pending.removeAll()
        clearLive()
    }

    var hasPendingWork: Bool { !pending.isEmpty || (!previewValid && !previewRendering) }

    /// Hands queued tiles to the workers (nearest to the visible centre first) while fewer
    /// than `limit` jobs are running; the preview goes first when it is due.
    func renderWork(limit: Int) {
        let queue = TileRenderQueue.shared
        if !previewValid, !previewRendering, queue.inFlight < limit,
           previewDirtyAt.map({ CACurrentMediaTime() - $0 > 0.6 }) ?? true {
            renderPreview()
        }
        guard renderScale > 0, !visibleRect.isNull else { return }
        if !pending.isEmpty && queue.inFlight < limit {
            let center = CGPoint(x: visibleRect.midX * renderScale, y: visibleRect.midY * renderScale)
            let ordered = pending.sorted { a, b in
                let ra = pixelRect(a), rb = pixelRect(b)
                return hypot(ra.midX - center.x, ra.midY - center.y) < hypot(rb.midX - center.x, rb.midY - center.y)
            }
            for key in ordered {
                if queue.inFlight >= limit { break }
                pending.remove(key)
                startTile(key)
            }
        }
        dropStaleIfDone()
    }

    private func dropStaleIfDone() {
        guard pending.isEmpty, inFlight == 0, let stale = staleContainer else { return }
        stale.removeFromSuperlayer()
        staleContainer = nil
    }

    private func tile(for key: TileKey) -> Tile {
        if let existing = tiles[key] { return existing }
        let tile = Tile()
        tiles[key] = tile
        tileContainer.addSublayer(tile.layer)
        return tile
    }

    /// Renders one tile on a worker; the result is used only if nothing changed meanwhile.
    private func startTile(_ key: TileKey) {
        let px = pixelRect(key)
        guard px.width > 0, px.height > 0 else { return }
        let tile = tile(for: key)
        let epoch = tile.epoch
        tile.renderingEpoch = epoch
        inFlight += 1
        let page = self.page, pdfPage = self.pdfPage, background = tile.background
        let snapshot = ink.snapshot(), scale = renderScale
        TileRenderQueue.shared.run({
            PageImageRenderer.tile(page: page, pdfPage: pdfPage, background: background, snapshot: snapshot,
                                   pixelRect: px, scale: scale)
        }, done: { [weak self] result in
            guard let self else { return }
            self.inFlight -= 1
            if tile.renderingEpoch == epoch { tile.renderingEpoch = nil }
            if self.tiles[key] === tile, tile.epoch == epoch, self.renderScale == scale, let image = result.image {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                if self.pdfPage != nil { tile.background = result.background }
                tile.layer.contents = image
                tile.layer.frame = self.layerFrame(px)
                tile.valid = true
                CATransaction.commit()
            } else if self.tiles[key] === tile, !tile.valid, !tile.isRendering, self.renderScale == scale {
                self.pending.insert(key)   // outdated result for a tile that is still wanted: render again
            }
            self.dropStaleIfDone()
        })
    }

    private static var scratch: [Int: CGContext] = [:]

    private static func scratchContext(_ w: Int, _ h: Int) -> CGContext? {
        let key = w * 100_000 + h
        if let ctx = scratch[key] { return ctx }
        if scratch.count > 16 { scratch.removeAll() }
        let ctx = Bitmaps.context(width: w, height: h)
        scratch[key] = ctx
        return ctx
    }

    /// Renders a tile right now on the main thread (pen-up, erasing, undo: no flicker).
    private func renderTile(_ key: TileKey) {
        let px = pixelRect(key)
        let w = Int(px.width), h = Int(px.height)
        guard w > 0, h > 0, let ctx = Self.scratchContext(w, h) else { return }
        let tile = tile(for: key)
        tile.epoch += 1   // a worker result started before this change is outdated
        if let background = tile.background {
            ctx.draw(background, in: CGRect(x: 0, y: 0, width: w, height: h))
        } else {
            PageImageRenderer.drawBackground(page: page, pdfPage: pdfPage, in: ctx, pixelWidth: w, pixelHeight: h,
                                             origin: px.origin, scale: renderScale)
            if pdfPage != nil { tile.background = ctx.makeImage() }
        }
        if let data = ctx.data {
            ink.renderOver(data, width: w, height: h, bytesPerRow: ctx.bytesPerRow, scale: Float(renderScale),
                           offsetX: Float(-px.minX), offsetY: Float(-px.minY))
        }
        tile.layer.contents = ctx.makeImage()
        tile.layer.frame = layerFrame(px)
        tile.valid = true
    }

    /// Ink changed in `pageRect`: re-render visible tiles there now, the rest later.
    func invalidate(_ pageRect: CGRect) {
        guard !pageRect.isNull else { return }
        previewValid = false
        previewEpoch += 1
        previewDirtyAt = CACurrentMediaTime()
        let affected = keys(intersecting: pageRect.insetBy(dx: -2, dy: -2))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for key in affected {
            guard tiles[key] != nil else { continue }
            renderTile(key)
            pending.remove(key)
        }
        CATransaction.commit()
    }

    func invalidateAll() {
        previewValid = false
        previewEpoch += 1
        for tile in tiles.values {
            tile.valid = false
            tile.background = nil
            tile.epoch += 1
        }
        pending.formUnion(tiles.keys)
    }

    /// Low-resolution whole-page image under the tiles, rendered on a worker.
    private func renderPreview() {
        let width = min(Int(CGFloat(page.size.width) * pointsPerUnit * screenScale), 1400)
        guard width > 0 else { return }
        let epoch = previewEpoch
        previewRendering = true
        inFlight += 1
        let page = self.page, pdfPage = self.pdfPage, snapshot = ink.snapshot()
        TileRenderQueue.shared.run({ () -> TileImage in
            let scale = CGFloat(width) / CGFloat(page.size.width)
            let height = Int((CGFloat(page.size.height) * scale).rounded())
            return PageImageRenderer.tile(page: page, pdfPage: pdfPage, background: nil, snapshot: snapshot,
                                          pixelRect: CGRect(x: 0, y: 0, width: width, height: height), scale: scale)
        }, done: { [weak self] result in
            guard let self else { return }
            self.inFlight -= 1
            self.previewRendering = false
            if epoch == self.previewEpoch, let image = result.image {
                self.previewLayer.contents = image
                self.previewValid = true
                self.previewDirtyAt = nil
            }
            self.dropStaleIfDone()
        })
    }

    // MARK: Live stroke overlay

    func setLiveMultiply(_ multiply: Bool) {
        overlayContainer.compositingFilter = multiply ? "multiplyBlendMode" : nil
    }

    func updateLive(_ builder: StrokeBuilder, dirty: CGRect) {
        guard renderScale > 0, !dirty.isNull else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for key in keys(intersecting: dirty.insetBy(dx: -1, dy: -1)) {
            let px = pixelRect(key)
            let w = Int(px.width), h = Int(px.height)
            guard w > 0, h > 0, let ctx = Self.scratchContext(w, h), let data = ctx.data else { continue }
            ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))
            builder.renderOver(data, width: w, height: h, bytesPerRow: ctx.bytesPerRow, scale: Float(renderScale),
                               offsetX: Float(-px.minX), offsetY: Float(-px.minY))
            let tileLayer: CALayer
            if let existing = overlayTiles[key] {
                tileLayer = existing
            } else {
                tileLayer = CALayer()
                tileLayer.actions = ["contents": NSNull(), "position": NSNull(), "bounds": NSNull()]
                overlayContainer.addSublayer(tileLayer)
                overlayTiles[key] = tileLayer
            }
            tileLayer.contents = ctx.makeImage()
            tileLayer.frame = layerFrame(px)
        }
        CATransaction.commit()
    }

    func clearLive() {
        for l in overlayTiles.values { l.removeFromSuperlayer() }
        overlayTiles.removeAll()
    }

    // MARK: Decorations

    func showLasso(_ points: [CGPoint]) {
        guard points.count > 1 else {
            lassoLayer.path = nil
            return
        }
        let path = UIBezierPath()
        path.move(to: CGPoint(x: points[0].x * pointsPerUnit, y: points[0].y * pointsPerUnit))
        for p in points.dropFirst() { path.addLine(to: CGPoint(x: p.x * pointsPerUnit, y: p.y * pointsPerUnit)) }
        path.close()
        lassoLayer.path = path.cgPath
    }

    func hideLasso() { lassoLayer.path = nil }

    /// Size of the corner handle used to resize a selection, in page units.
    var handleRadius: CGFloat { 14 / pointsPerUnit }

    func handleCenter(for bounds: CGRect) -> CGPoint {
        CGPoint(x: bounds.maxX + 6 / pointsPerUnit, y: bounds.maxY + 6 / pointsPerUnit)
    }

    func showSelection(_ pageBounds: CGRect?, zoom: CGFloat) {
        guard let pageBounds, !pageBounds.isNull else {
            selectionLayer.path = nil
            handleLayer.path = nil
            return
        }
        let r = viewRect(pageBounds.insetBy(dx: -6 / pointsPerUnit, dy: -6 / pointsPerUnit))
        selectionLayer.lineWidth = 1.5 / max(zoom, 0.1)
        selectionLayer.path = UIBezierPath(roundedRect: r, cornerRadius: 6 / max(zoom, 0.1)).cgPath
        let hc = handleCenter(for: pageBounds)
        let radius = 7 / max(zoom, 0.1)
        handleLayer.lineWidth = 1.5 / max(zoom, 0.1)
        handleLayer.path = UIBezierPath(ovalIn: CGRect(x: hc.x * pointsPerUnit - radius, y: hc.y * pointsPerUnit - radius,
                                                       width: radius * 2, height: radius * 2)).cgPath
    }

    /// Draws `ids` into the floating layer that follows the finger while moving a selection.
    func showFloating(_ ids: [StrokeID], bounds pageBounds: CGRect) {
        let pad: CGFloat = 4
        let rect = pageBounds.insetBy(dx: -pad, dy: -pad)
        let scale = min(renderScale, 4096 / max(rect.width, rect.height, 1))
        let w = Int((rect.width * scale).rounded(.up)), h = Int((rect.height * scale).rounded(.up))
        guard w > 0, h > 0, let ctx = Bitmaps.context(width: w, height: h), let data = ctx.data else { return }
        ink.renderStrokesOver(ids, data, width: w, height: h, bytesPerRow: ctx.bytesPerRow, scale: Float(scale),
                              offsetX: Float(-rect.minX * scale), offsetY: Float(-rect.minY * scale))
        floatingLayer.contents = ctx.makeImage()
        floatingLayer.transform = CATransform3DIdentity
        floatingLayer.frame = viewRect(rect)
        floatingLayer.isHidden = false
    }

    func moveFloating(by delta: CGPoint, scale: CGFloat = 1, anchor: CGPoint = .zero) {
        // `anchor` and `delta` are page units; the layer is positioned in view points.
        var t = CATransform3DIdentity
        if scale != 1 {
            let a = CGPoint(x: anchor.x * pointsPerUnit - floatingLayer.position.x,
                            y: anchor.y * pointsPerUnit - floatingLayer.position.y)
            t = CATransform3DTranslate(t, a.x, a.y, 0)
            t = CATransform3DScale(t, scale, scale, 1)
            t = CATransform3DTranslate(t, -a.x, -a.y, 0)
        }
        t = CATransform3DConcat(t, CATransform3DMakeTranslation(delta.x * pointsPerUnit, delta.y * pointsPerUnit, 0))
        floatingLayer.transform = t
    }

    func hideFloating() {
        floatingLayer.contents = nil
        floatingLayer.isHidden = true
        floatingLayer.transform = CATransform3DIdentity
    }

    func showEraser(at pagePoint: CGPoint?, diameter: CGFloat) {
        guard let pagePoint else {
            eraserCursor.isHidden = true
            return
        }
        let c = CGPoint(x: pagePoint.x * pointsPerUnit, y: pagePoint.y * pointsPerUnit)
        eraserCursor.lineWidth = 1
        eraserCursor.path = UIBezierPath(ovalIn: CGRect(x: c.x - diameter / 2, y: c.y - diameter / 2,
                                                        width: diameter, height: diameter)).cgPath
        eraserCursor.isHidden = false
    }

    func flashHighlight(_ pageRect: CGRect) {
        highlightLayer.frame = viewRect(pageRect.insetBy(dx: -2, dy: -2))
        highlightLayer.isHidden = false
        highlightLayer.opacity = 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            self?.highlightLayer.isHidden = true
        }
    }

    // MARK: Paper & elements

    func updatePage(_ newPage: NotebookPage) {
        let backgroundChanged = newPage.paper != page.paper || newPage.size != page.size
        page = newPage
        if backgroundChanged {
            backgroundColor = pdfPage != nil ? .white : PaperRenderer.color(page.paper)
            previewDirtyAt = nil
            invalidateAll()
        }
        syncElements(newPage.elements)
    }

    func syncElements(_ elements: [PageElement]) {
        let ids = Set(elements.map(\.id))
        for (id, view) in elementViews where !ids.contains(id) {
            view.removeFromSuperview()
            elementViews[id] = nil
        }
        for element in elements {
            if let view = elementViews[element.id] {
                view.update(element)
            } else {
                let view = ElementView(element: element, package: package, pointsPerUnit: pointsPerUnit)
                view.isUserInteractionEnabled = elementsInteractive
                view.textEditable = textEditingEnabled
                view.onChange = { [weak self] in self?.onElementChange?($0) }
                view.onDelete = { [weak self] in self?.onElementDelete?($0) }
                addSubview(view)
                elementViews[element.id] = view
            }
        }
    }

    func beginEditing(elementID: UUID) {
        elementViews[elementID]?.beginEditing()
    }

    func zoomChanged(_ zoom: CGFloat) {
        for view in elementViews.values { view.setRenderZoom(zoom * screenScale) }
    }
}

/// A text box or an image placed on a page.
final class ElementView: UIView, UITextViewDelegate {
    private(set) var element: PageElement
    var pointsPerUnit: CGFloat { didSet { applyFrame() } }
    var onChange: ((PageElement) -> Void)?
    var onDelete: ((UUID) -> Void)?
    var textEditable = false { didSet { textView?.isEditable = textEditable } }

    private var textView: UITextView?
    private var imageView: UIImageView?
    private var panStart: CGPoint = .zero
    private var pinchStart: ElementFrame?

    init(element: PageElement, package: NotebookPackage, pointsPerUnit: CGFloat) {
        self.element = element
        self.pointsPerUnit = pointsPerUnit
        super.init(frame: .zero)
        switch element.kind {
        case .text:
            let tv = UITextView()
            tv.backgroundColor = .clear
            tv.isScrollEnabled = false
            tv.textContainerInset = .zero
            tv.textContainer.lineFragmentPadding = 0
            tv.delegate = self
            tv.isEditable = false
            tv.text = element.text
            addSubview(tv)
            textView = tv
        case .image:
            let iv = UIImageView()
            iv.contentMode = .scaleAspectFit
            if let name = element.asset { iv.image = UIImage(contentsOfFile: package.assetURL(name).path) }
            addSubview(iv)
            imageView = iv
            let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))
            addGestureRecognizer(pinch)
        }
        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        pan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue),
                                 NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        addGestureRecognizer(pan)
        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(longPressed(_:)))
        addGestureRecognizer(longPress)
        layer.borderColor = NoteTheme.accentUI.withAlphaComponent(0.5).cgColor
        apply(element)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isUserInteractionEnabled: Bool {
        didSet { layer.borderWidth = isUserInteractionEnabled ? 1 : 0 }
    }

    func update(_ newElement: PageElement) {
        guard newElement != element else { return }
        element = newElement
        if textView?.isFirstResponder != true { textView?.text = newElement.text }
        apply(newElement)
    }

    private func apply(_ e: PageElement) {
        textView?.font = UIFont.systemFont(ofSize: CGFloat(e.fontSize ?? 16) * pointsPerUnit)
        textView?.textColor = UIColor(hex: e.colorHex ?? "#1C1C1E")
        applyFrame()
    }

    private func applyFrame() {
        let f = element.frame
        frame = CGRect(x: f.x * pointsPerUnit, y: f.y * pointsPerUnit, width: f.width * pointsPerUnit,
                       height: f.height * pointsPerUnit)
        textView?.font = UIFont.systemFont(ofSize: CGFloat(element.fontSize ?? 16) * pointsPerUnit)
        textView?.frame = bounds
        imageView?.frame = bounds
    }

    func setRenderZoom(_ scale: CGFloat) {
        textView?.contentScaleFactor = scale
        for sub in textView?.subviews ?? [] { sub.contentScaleFactor = scale }
    }

    func beginEditing() {
        textView?.isEditable = true
        textView?.becomeFirstResponder()
    }

    func textViewDidChange(_ textView: UITextView) {
        // Grow the box with its text.
        let fitting = textView.sizeThatFits(CGSize(width: bounds.width, height: .greatestFiniteMagnitude))
        if abs(fitting.height - bounds.height) > 1 {
            element.frame.height = Double(max(fitting.height, 20) / pointsPerUnit)
            applyFrame()
        }
    }

    func textViewDidEndEditing(_ textView: UITextView) {
        let text = textView.text ?? ""
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            onDelete?(element.id)
            return
        }
        element.text = text
        onChange?(element)
    }

    @objc private func panned(_ g: UIPanGestureRecognizer) {
        guard let superview else { return }
        switch g.state {
        case .began:
            panStart = CGPoint(x: element.frame.x, y: element.frame.y)
        case .changed:
            let t = g.translation(in: superview)
            element.frame.x = Double(panStart.x + t.x / pointsPerUnit)
            element.frame.y = Double(panStart.y + t.y / pointsPerUnit)
            applyFrame()
        case .ended:
            onChange?(element)
        default:
            break
        }
    }

    @objc private func pinched(_ g: UIPinchGestureRecognizer) {
        switch g.state {
        case .began:
            pinchStart = element.frame
        case .changed:
            guard let start = pinchStart else { return }
            let s = Double(g.scale)
            element.frame = ElementFrame(x: start.x + start.width * (1 - s) / 2, y: start.y + start.height * (1 - s) / 2,
                                         width: start.width * s, height: start.height * s)
            applyFrame()
        case .ended:
            onChange?(element)
        default:
            break
        }
    }

    @objc private func longPressed(_ g: UILongPressGestureRecognizer) {
        guard g.state == .began else { return }
        let alert = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
        alert.addAction(UIAlertAction(title: "삭제", style: .destructive) { [weak self] _ in
            guard let self else { return }
            self.onDelete?(self.element.id)
        })
        alert.addAction(UIAlertAction(title: "취소", style: .cancel))
        alert.popoverPresentationController?.sourceView = self
        alert.popoverPresentationController?.sourceRect = bounds
        var responder: UIResponder? = self
        while let r = responder, !(r is UIViewController) { responder = r.next }
        (responder as? UIViewController)?.present(alert, animated: true)
    }
}
#endif
