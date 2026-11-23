#if canImport(UIKit)
import InkBridge
import NoteKit
import PhotosUI
import SwiftUI
import UIKit

/// Receives touches for the whole canvas (pages forward theirs up the responder chain).
final class CanvasContentView: UIView {
    weak var controller: CanvasViewController?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        controller?.touchesBegan(touches, event: event)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        controller?.touchesMoved(touches, event: event)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        controller?.touchesEnded(touches, event: event)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        controller?.touchesCancelled(touches, event: event)
    }

    override func touchesEstimatedPropertiesUpdated(_ touches: Set<UITouch>) {
        controller?.estimatedPropertiesUpdated(touches)
    }
}

private struct Selection {
    let pageID: UUID
    var ids: [StrokeID]
    var bounds: CGRect
}

private enum Interaction {
    case idle
    case drawing
    case erasing(didErase: Bool)
    case lassoing
    case movingSelection(start: CGPoint, delta: CGPoint)
    case scalingSelection(start: CGPoint, scale: CGFloat)
    case laser
    case tap(start: CGPoint)
}

/// The notebook canvas: pages stacked vertically in a zoomable scroll view.
final class CanvasViewController: UIViewController, UIScrollViewDelegate, CanvasControlling,
    UIPencilInteractionDelegate, UIEditMenuInteractionDelegate, PHPickerViewControllerDelegate {
    let model: EditorModel

    private let scrollView = UIScrollView()
    private let contentView = CanvasContentView()
    private var pageFrames: [CGRect] = []
    private var pageViews: [UUID: PageView] = [:]
    private var layoutScale: CGFloat = 1
    private var lastLayoutWidth: CGFloat = 0
    private var renderZoom: CGFloat = 1
    private var displayLink: CADisplayLink?
    private let builder = StrokeBuilder(kind: .ballpoint)
    private var activeTouch: UITouch?
    private var activePage: PageView?
    private var interaction: Interaction = .idle
    private var lassoPoints: [CGPoint] = []
    private var selection: Selection?
    private var editMenu: UIEditMenuInteraction?
    private let laserLayer = CAShapeLayer()
    private var laserPath = UIBezierPath()
    private let haptics = UIImpactFeedbackGenerator(style: .light)
    private var pendingFocus: UUID?
    private var pendingImagePoint: (UUID, CGPoint)?
    private var twoFingerTap: UITapGestureRecognizer?
    private var threeFingerTap: UITapGestureRecognizer?

    init(model: EditorModel) {
        self.model = model
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private var settings: AppSettings { model.app.settings }
    private var tools: ToolState { model.tools }
    private var screenScale: CGFloat { view.window?.screen.scale ?? traitCollection.displayScale }

    // MARK: View lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = NoteTheme.deskUI
        scrollView.frame = view.bounds
        scrollView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scrollView.delegate = self
        scrollView.minimumZoomScale = 0.5
        scrollView.maximumZoomScale = 5
        scrollView.delaysContentTouches = false
        scrollView.canCancelContentTouches = true
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.backgroundColor = .clear
        scrollView.decelerationRate = .normal
        view.addSubview(scrollView)

        contentView.controller = self
        contentView.isMultipleTouchEnabled = true
        scrollView.addSubview(contentView)

        laserLayer.strokeColor = UIColor.systemRed.cgColor
        laserLayer.fillColor = UIColor.clear.cgColor
        laserLayer.lineWidth = 4
        laserLayer.lineCap = .round
        laserLayer.lineJoin = .round
        laserLayer.shadowColor = UIColor.systemRed.cgColor
        laserLayer.shadowOpacity = 0.9
        laserLayer.shadowRadius = 6
        laserLayer.shadowOffset = .zero
        view.layer.addSublayer(laserLayer)

        let menu = UIEditMenuInteraction(delegate: self)
        view.addInteraction(menu)
        editMenu = menu

        let pencil = UIPencilInteraction()
        pencil.delegate = self
        view.addInteraction(pencil)

        let two = UITapGestureRecognizer(target: self, action: #selector(twoFingerTapped))
        two.numberOfTouchesRequired = 2
        two.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        scrollView.addGestureRecognizer(two)
        twoFingerTap = two
        let three = UITapGestureRecognizer(target: self, action: #selector(threeFingerTapped))
        three.numberOfTouchesRequired = 3
        three.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        scrollView.addGestureRecognizer(three)
        threeFingerTap = three

        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(longPressed(_:)))
        longPress.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        scrollView.addGestureRecognizer(longPress)

        model.canvas = self
        NotificationCenter.default.addObserver(self, selector: #selector(pasteRequested), name: .canvasPaste, object: nil)
        applySettings()
    }

    @objc private func pasteRequested() { paste() }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        let link = CADisplayLink(target: self, selector: #selector(frameTick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        displayLink = link
        scrollToPage(model.currentPageIndex, animated: false)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        displayLink?.invalidate()
        displayLink = nil
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        if abs(scrollView.bounds.width - lastLayoutWidth) > 0.5 {
            let index = model.currentPageIndex
            relayout()
            scrollToPage(index, animated: false)
        }
    }

    /// Re-reads tool and settings state (called by SwiftUI on every model change).
    func applySettings() {
        let direct = NSNumber(value: UITouch.TouchType.direct.rawValue)
        let indirect = NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)
        // Pencil never scrolls. With finger drawing on, scrolling takes two fingers.
        scrollView.panGestureRecognizer.allowedTouchTypes = [direct, indirect]
        scrollView.panGestureRecognizer.minimumNumberOfTouches = settings.pencilOnly ? 1 : 2
        scrollView.pinchGestureRecognizer?.allowedTouchTypes = [direct]
        twoFingerTap?.isEnabled = settings.tapGesturesUndo
        threeFingerTap?.isEnabled = settings.tapGesturesUndo
        let tool = tools.tool
        for pv in pageViews.values {
            pv.elementsInteractive = tool == .text || tool == .image || tool == .lasso
            pv.textEditingEnabled = tool == .text
        }
        if tool != .lasso { clearSelection() }
    }

    // MARK: Layout

    private func relayout() {
        let width = scrollView.bounds.width
        guard width > 0 else { return }
        lastLayoutWidth = width
        let margin: CGFloat = width > 700 ? 40 : 12
        let maxPageWidth = CGFloat(model.document.pages.map(\.size.width).max() ?? 595)
        layoutScale = max((width - margin * 2) / maxPageWidth, 0.1)
        var y: CGFloat = 24
        pageFrames = model.document.pages.map { page in
            let w = CGFloat(page.size.width) * layoutScale, h = CGFloat(page.size.height) * layoutScale
            let frame = CGRect(x: ((width - w) / 2).rounded(), y: y.rounded(), width: w.rounded(), height: h.rounded())
            y += h + 24
            return frame
        }
        let contentSize = CGSize(width: width, height: y + 80)
        let zoom = scrollView.zoomScale
        contentView.bounds = CGRect(origin: .zero, size: contentSize)
        contentView.center = CGPoint(x: contentSize.width * zoom / 2, y: contentSize.height * zoom / 2)
        scrollView.contentSize = CGSize(width: contentSize.width * zoom, height: contentSize.height * zoom)
        for (id, pv) in pageViews {
            guard let index = model.document.pageIndex(of: id) else { continue }
            pv.setPointsPerUnit(layoutScale)
            pv.frame = pageFrames[index]
        }
        centerContent()
        updateVisiblePages()
    }

    private func centerContent() {
        let size = contentView.frame.size
        let insetX = max(0, (scrollView.bounds.width - size.width) / 2)
        scrollView.contentInset = UIEdgeInsets(top: 0, left: insetX, bottom: 0, right: insetX)
    }

    private var currentRenderScale: CGFloat { layoutScale * renderZoom * screenScale }

    private func updateVisiblePages() {
        guard !pageFrames.isEmpty else { return }
        let visible = scrollView.convert(scrollView.bounds, to: contentView)
        let keepAlive = visible.insetBy(dx: 0, dy: -visible.height)
        let pages = model.document.pages
        var wanted = Set<UUID>()
        for (index, frame) in pageFrames.enumerated() where frame.intersects(keepAlive) && index < pages.count {
            let page = pages[index]
            wanted.insert(page.id)
            let pv: PageView
            if let existing = pageViews[page.id] {
                pv = existing
                if pv.frame != frame { pv.frame = frame }
            } else {
                pv = PageView(page: page, ink: model.inkPage(page.id), pdfPage: model.pdfPage(for: page),
                              package: model.package, pointsPerUnit: layoutScale)
                pv.screenScale = screenScale
                pv.frame = frame
                pv.elementsInteractive = tools.tool == .text || tools.tool == .image || tools.tool == .lasso
                pv.textEditingEnabled = tools.tool == .text
                let pageID = page.id
                pv.onElementChange = { [weak self] element in self?.model.updateElement(element, onPage: pageID) }
                pv.onElementDelete = { [weak self] id in self?.model.removeElement(id, fromPage: pageID) }
                pv.zoomChanged(renderZoom)
                contentView.addSubview(pv)
                pageViews[page.id] = pv
            }
            let part = frame.intersection(visible)
            let pageRect = part.isNull || part.isEmpty ? CGRect.null
                : CGRect(x: (part.minX - frame.minX) / layoutScale, y: (part.minY - frame.minY) / layoutScale,
                         width: part.width / layoutScale, height: part.height / layoutScale)
            pv.setVisible(pageRect, renderScale: currentRenderScale)
        }
        for (id, pv) in pageViews where !wanted.contains(id) && pv !== activePage {
            pv.removeFromSuperview()
            pageViews[id] = nil
        }
        // Current page = the one under the middle of the screen.
        let mid = CGPoint(x: visible.midX, y: visible.midY)
        if let index = pageFrames.firstIndex(where: { $0.insetBy(dx: -12, dy: -12).contains(mid) }),
           index != model.currentPageIndex {
            model.currentPageIndex = index
        }
    }

    // MARK: Frame loop

    @objc private func frameTick(_ link: CADisplayLink) {
        if case .drawing = interaction, let pv = activePage, builder.isActive {
            if builder.tick(now: CACurrentMediaTime()) { haptics.impactOccurred() }
            let dirty = builder.updateGeometry(pixelsPerUnit: Float(pv.renderScale))
            pv.updateLive(builder, dirty: dirty)
        }
        // Background tile work, nearest pages first, within a frame budget.
        let budget: CFTimeInterval
        if case .drawing = interaction { budget = 0.002 } else { budget = 0.007 }
        let deadline = CACurrentMediaTime() + budget
        let mid = scrollView.convert(CGPoint(x: scrollView.bounds.midX, y: scrollView.bounds.midY), to: contentView)
        let ordered = pageViews.values.filter(\.hasPendingWork).sorted {
            abs($0.frame.midY - mid.y) < abs($1.frame.midY - mid.y)
        }
        for pv in ordered {
            if CACurrentMediaTime() > deadline { break }
            pv.renderWork(until: deadline)
        }
    }

    // MARK: Scroll view

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { contentView }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        updateVisiblePages()
        if selection != nil { editMenu?.dismissMenu() }
    }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerContent()
        updateVisiblePages()
    }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        renderZoom = scale
        for pv in pageViews.values { pv.zoomChanged(scale) }
        updateVisiblePages()
        if let selection, let pv = pageViews[selection.pageID] { pv.showSelection(selection.bounds, zoom: scale) }
    }

    // MARK: Page lookup

    private func pageView(at contentPoint: CGPoint) -> PageView? {
        pageViews.values.first { $0.frame.insetBy(dx: -8, dy: -8).contains(contentPoint) }
    }

    private func pagePoint(_ touch: UITouch, in pv: PageView, precise: Bool = true) -> CGPoint {
        pv.pagePoint(precise ? touch.preciseLocation(in: pv) : touch.location(in: pv))
    }

    private func isDrawingTouch(_ touch: UITouch) -> Bool {
        touch.type == .pencil || (!settings.pencilOnly && touch.type == .direct)
    }

    private func sample(_ t: UITouch, in pv: PageView) -> PenSample {
        let p = pagePoint(t, in: pv)
        var s = PenSample(x: Float(p.x), y: Float(p.y), time: t.timestamp, isPencil: t.type == .pencil)
        if t.type == .pencil {
            s.pressure = Float(t.force / max(t.maximumPossibleForce, 0.0001))
            s.altitude = Float(t.altitudeAngle)
            s.azimuth = Float(t.azimuthAngle(in: pv))
            s.expectsPressureUpdate = t.estimatedPropertiesExpectingUpdates.contains(.force)
            s.expectsTiltUpdate = t.estimatedPropertiesExpectingUpdates.contains(.altitude)
        }
        if let index = t.estimationUpdateIndex { s.updateID = index.uint64Value }
        return s
    }

    private func feed(_ t: UITouch, _ event: UIEvent?, into pv: PageView) {
        let coalesced = event?.coalescedTouches(for: t) ?? [t]
        builder.add(coalesced.map { sample($0, in: pv) })
        let predicted = event?.predictedTouches(for: t) ?? []
        builder.setPredicted(predicted.map { sample($0, in: pv) })
    }

    // MARK: Touches

    func touchesBegan(_ touches: Set<UITouch>, event: UIEvent?) {
        if activeTouch != nil {
            // A finger resting while drawing → perfect shapes.
            if case .drawing = interaction, touches.contains(where: { $0.type == .direct }) {
                builder.setShapeConstraint(true)
            }
            return
        }
        guard let touch = touches.first(where: isDrawingTouch) else { return }
        let point = touch.location(in: contentView)
        let tool = tools.tool
        if tool == .laser {
            activeTouch = touch
            interaction = .laser
            laserLayer.removeAllAnimations()
            laserLayer.opacity = 1
            laserPath = UIBezierPath()
            laserPath.move(to: touch.location(in: view))
            laserLayer.path = laserPath.cgPath
            return
        }
        guard let pv = pageView(at: point) else {
            if tool == .lasso { clearSelection() }
            return
        }
        activeTouch = touch
        activePage = pv
        editMenu?.dismissMenu()
        let p = pagePoint(touch, in: pv)
        switch tool {
        case .pen, .highlighter:
            interaction = .drawing
            tools.configure(builder, viewScale: Float(layoutScale * scrollView.zoomScale))
            builder.setShapeConstraint(false)
            pv.setLiveMultiply(tool == .highlighter)
            builder.begin(sample(touch, in: pv))
            feed(touch, event, into: pv)
            haptics.prepare()
        case .eraser:
            interaction = .erasing(didErase: false)
            let radius = CGFloat(tools.eraserSize) / 2 / (layoutScale * scrollView.zoomScale)
            pv.ink.eraseBegin(mode: tools.eraserMode, radius: Float(radius),
                              highlighterOnly: tools.eraseHighlighterOnly, at: p)
            pv.showEraser(at: p, diameter: CGFloat(tools.eraserSize) / scrollView.zoomScale)
        case .lasso:
            beginLasso(at: p, in: pv)
        case .text, .image:
            interaction = .tap(start: p)
        case .laser:
            break
        }
    }

    func touchesMoved(_ touches: Set<UITouch>, event: UIEvent?) {
        guard let touch = activeTouch, touches.contains(touch) else { return }
        if case .laser = interaction {
            for t in event?.coalescedTouches(for: touch) ?? [touch] { laserPath.addLine(to: t.location(in: view)) }
            laserLayer.path = laserPath.cgPath
            return
        }
        guard let pv = activePage else { return }
        switch interaction {
        case .drawing:
            feed(touch, event, into: pv)
        case .erasing(let didErase):
            var erased = didErase
            for t in event?.coalescedTouches(for: touch) ?? [touch] {
                if pv.ink.eraseMove(to: pagePoint(t, in: pv)) { erased = true }
            }
            interaction = .erasing(didErase: erased)
            pv.invalidate(pv.ink.takeDirty())
            pv.showEraser(at: pagePoint(touch, in: pv), diameter: CGFloat(tools.eraserSize) / scrollView.zoomScale)
        case .lassoing:
            for t in event?.coalescedTouches(for: touch) ?? [touch] { lassoPoints.append(pagePoint(t, in: pv)) }
            pv.showLasso(lassoPoints)
        case .movingSelection(let start, _):
            guard let sel = selection else { return }
            let p = pagePoint(touch, in: pv)
            let delta = CGPoint(x: p.x - start.x, y: p.y - start.y)
            interaction = .movingSelection(start: start, delta: delta)
            pv.moveFloating(by: delta)
            pv.showSelection(sel.bounds.offsetBy(dx: delta.x, dy: delta.y), zoom: scrollView.zoomScale)
        case .scalingSelection(let start, _):
            guard let sel = selection else { return }
            let p = pagePoint(touch, in: pv)
            let anchor = sel.bounds.origin
            let d0 = hypot(start.x - anchor.x, start.y - anchor.y)
            let d1 = hypot(p.x - anchor.x, p.y - anchor.y)
            let scale = min(max(d1 / max(d0, 1), 0.2), 8)
            interaction = .scalingSelection(start: start, scale: scale)
            pv.moveFloating(by: .zero, scale: scale, anchor: anchor)
            let scaled = CGRect(x: anchor.x, y: anchor.y, width: sel.bounds.width * scale, height: sel.bounds.height * scale)
            pv.showSelection(scaled, zoom: scrollView.zoomScale)
        default:
            break
        }
    }

    func touchesEnded(_ touches: Set<UITouch>, event: UIEvent?) {
        if activeTouch == nil || !touches.contains(activeTouch!) {
            if touches.contains(where: { $0.type == .direct }) { builder.setShapeConstraint(false) }
            return
        }
        let touch = activeTouch!
        defer {
            activeTouch = nil
            activePage = nil
            interaction = .idle
        }
        if case .laser = interaction {
            fadeLaser()
            return
        }
        guard let pv = activePage else { return }
        switch interaction {
        case .drawing:
            feed(touch, event, into: pv)
            builder.end()
            let id = pv.ink.commit(builder)
            pv.invalidate(pv.ink.takeDirty())   // new stroke into the tiles first…
            pv.clearLive()                       // …then drop the overlay: no flicker
            if id != 0 { model.noteInkEdit(pv.pageID) }
        case .erasing(let didErase):
            pv.ink.eraseEnd()
            pv.invalidate(pv.ink.takeDirty())
            pv.showEraser(at: nil, diameter: 0)
            if didErase { model.noteInkEdit(pv.pageID) }
        case .lassoing:
            finishLasso(in: pv)
        case .movingSelection(_, let delta):
            finishMove(in: pv, transform: .translation(Float(delta.x), Float(delta.y)), moved: delta != .zero)
        case .scalingSelection(_, let scale):
            guard let sel = selection else { return }
            let t = InkAffine.scale(Float(scale), aroundX: Float(sel.bounds.minX), y: Float(sel.bounds.minY))
            finishMove(in: pv, transform: t, moved: abs(scale - 1) > 0.01)
        case .tap(let start):
            let p = pagePoint(touch, in: pv)
            guard hypot(p.x - start.x, p.y - start.y) < 12 / layoutScale else { return }
            if tools.tool == .text { addTextBox(at: p, in: pv) } else { pickImage(at: p, in: pv) }
        default:
            break
        }
    }

    func touchesCancelled(_ touches: Set<UITouch>, event: UIEvent?) {
        guard let touch = activeTouch, touches.contains(touch) else { return }
        if let pv = activePage {
            switch interaction {
            case .drawing:
                builder.cancel()
                pv.clearLive()
            case .erasing(let didErase):
                pv.ink.eraseEnd()
                pv.invalidate(pv.ink.takeDirty())
                pv.showEraser(at: nil, diameter: 0)
                if didErase { model.noteInkEdit(pv.pageID) }
            case .lassoing:
                pv.hideLasso()
            case .movingSelection, .scalingSelection:
                finishMove(in: pv, transform: .translation(0, 0), moved: false)
            default:
                break
            }
        }
        if case .laser = interaction { fadeLaser() }
        activeTouch = nil
        activePage = nil
        interaction = .idle
    }

    func estimatedPropertiesUpdated(_ touches: Set<UITouch>) {
        guard case .drawing = interaction, let pv = activePage else { return }
        for t in touches {
            guard let index = t.estimationUpdateIndex else { continue }
            builder.updateEstimated(id: index.uint64Value, pressure: Float(t.force / max(t.maximumPossibleForce, 0.0001)),
                                    altitude: Float(t.altitudeAngle), azimuth: Float(t.azimuthAngle(in: pv)))
        }
    }

    // MARK: Lasso

    private func beginLasso(at p: CGPoint, in pv: PageView) {
        if let sel = selection, sel.pageID == pv.pageID {
            let handle = pv.handleCenter(for: sel.bounds)
            if hypot(p.x - handle.x, p.y - handle.y) < pv.handleRadius * 1.6 / scrollView.zoomScale + 4 {
                startFloating(sel, in: pv)
                interaction = .scalingSelection(start: p, scale: 1)
                return
            }
            if sel.bounds.insetBy(dx: -10 / layoutScale, dy: -10 / layoutScale).contains(p) {
                startFloating(sel, in: pv)
                interaction = .movingSelection(start: p, delta: .zero)
                return
            }
        }
        clearSelection()
        interaction = .lassoing
        lassoPoints = [p]
    }

    private func finishLasso(in pv: PageView) {
        pv.hideLasso()
        let ids = pv.ink.selectLasso(lassoPoints)
        lassoPoints = []
        guard !ids.isEmpty else { return }
        let bounds = pv.ink.bounds(of: ids)
        selection = Selection(pageID: pv.pageID, ids: ids, bounds: bounds)
        pv.showSelection(bounds, zoom: scrollView.zoomScale)
        presentSelectionMenu()
    }

    private func startFloating(_ sel: Selection, in pv: PageView) {
        pv.ink.setHidden(sel.ids)
        pv.invalidate(sel.bounds.insetBy(dx: -4, dy: -4))
        pv.showFloating(sel.ids, bounds: sel.bounds)
    }

    private func finishMove(in pv: PageView, transform: InkAffine, moved: Bool) {
        guard var sel = selection else { return }
        pv.ink.setHidden([])
        if moved, pv.ink.transform(sel.ids, transform) {
            model.noteInkEdit(pv.pageID)
        }
        var dirty = pv.ink.takeDirty()
        dirty = dirty.isNull ? sel.bounds : dirty.union(sel.bounds)
        pv.invalidate(dirty.insetBy(dx: -4, dy: -4))
        pv.hideFloating()
        sel.bounds = pv.ink.bounds(of: sel.ids)
        selection = sel
        pv.showSelection(sel.bounds, zoom: scrollView.zoomScale)
        presentSelectionMenu()
    }

    func clearSelection() {
        if let sel = selection, let pv = pageViews[sel.pageID] {
            pv.showSelection(nil, zoom: scrollView.zoomScale)
            pv.hideFloating()
            pv.ink.setHidden([])
        }
        selection = nil
        editMenu?.dismissMenu()
    }

    private func presentSelectionMenu() {
        guard let sel = selection, let pv = pageViews[sel.pageID] else { return }
        let rect = pv.convert(pv.viewRect(sel.bounds), to: view)
        let point = CGPoint(x: rect.midX, y: rect.maxY + 12)
        editMenu?.presentEditMenu(with: UIEditMenuConfiguration(identifier: "selection" as NSString, sourcePoint: point))
    }

    private func applyToSelection(_ operation: (InkPage, [StrokeID]) -> Bool) {
        guard let sel = selection, let pv = pageViews[sel.pageID] else { return }
        if operation(pv.ink, sel.ids) { model.noteInkEdit(pv.pageID) }
        pv.invalidate(pv.ink.takeDirty())
        let bounds = pv.ink.bounds(of: sel.ids)
        if bounds.isNull {
            clearSelection()
        } else {
            selection?.bounds = bounds
            pv.showSelection(bounds, zoom: scrollView.zoomScale)
            presentSelectionMenu()
        }
    }

    private func copySelection() {
        guard let sel = selection, let pv = pageViews[sel.pageID] else { return }
        model.app.strokeClipboard = pv.ink.copyStrokes(sel.ids)
    }

    func paste(at contentPoint: CGPoint? = nil) {
        guard let data = model.app.strokeClipboard else { return }
        let index = model.currentPageIndex
        guard let page = model.document.pages[safe: index], let pv = pageViews[page.id] else { return }
        // Measure the clipboard on a scratch page, then paste centred where the user looks.
        let scratch = InkPage(width: Float(page.size.width), height: Float(page.size.height))
        let probe = scratch.paste(data, dx: 0, dy: 0)
        let bounds = scratch.bounds(of: probe)
        guard !bounds.isNull else { return }
        let target: CGPoint
        if let contentPoint {
            target = pv.pagePoint(contentView.convert(contentPoint, to: pv))
        } else {
            let visible = scrollView.convert(scrollView.bounds, to: pv)
            target = pv.pagePoint(CGPoint(x: visible.midX, y: visible.midY))
        }
        let dx = Float(target.x - bounds.midX), dy = Float(target.y - bounds.midY)
        let ids = pv.ink.paste(data, dx: dx, dy: dy)
        guard !ids.isEmpty else { return }
        model.noteInkEdit(page.id)
        pv.invalidate(pv.ink.takeDirty())
        model.tools.select(.lasso)
        applySettings()
        let newBounds = pv.ink.bounds(of: ids)
        selection = Selection(pageID: page.id, ids: ids, bounds: newBounds)
        pv.showSelection(newBounds, zoom: scrollView.zoomScale)
        presentSelectionMenu()
    }

    func editMenuInteraction(_ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration,
                             suggestedActions: [UIMenuElement]) -> UIMenu? {
        if configuration.identifier as? String == "paste" {
            return UIMenu(children: [UIAction(title: "붙여넣기", image: UIImage(systemName: "doc.on.clipboard")) { [weak self] _ in
                self?.paste(at: self?.lastLongPressPoint)
            }])
        }
        guard selection != nil else { return nil }
        let colors = NoteTheme.penColors.map { hex in
            UIAction(title: hex, image: UIImage(systemName: "circle.fill")?.withTintColor(UIColor(hex: hex),
                                                                                            renderingMode: .alwaysOriginal)) { [weak self] _ in
                self?.applyToSelection { $0.recolor($1, InkRGBA(hex: hex)) }
            }
        }
        return UIMenu(children: [
            UIAction(title: "복사", image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in self?.copySelection() },
            UIAction(title: "잘라내기", image: UIImage(systemName: "scissors")) { [weak self] _ in
                self?.copySelection()
                self?.applyToSelection { $0.delete($1) }
            },
            UIAction(title: "복제", image: UIImage(systemName: "plus.square.on.square")) { [weak self] _ in
                guard let self, let sel = self.selection, let pv = self.pageViews[sel.pageID] else { return }
                let ids = pv.ink.duplicate(sel.ids, dx: 16, dy: 16)
                guard !ids.isEmpty else { return }
                self.model.noteInkEdit(pv.pageID)
                pv.invalidate(pv.ink.takeDirty())
                self.selection = Selection(pageID: sel.pageID, ids: ids, bounds: pv.ink.bounds(of: ids))
                pv.showSelection(self.selection?.bounds, zoom: self.scrollView.zoomScale)
                self.presentSelectionMenu()
            },
            UIMenu(title: "색 변경", image: UIImage(systemName: "paintpalette"), children: colors),
            UIAction(title: "줄 정렬", image: UIImage(systemName: "text.alignleft")) { [weak self] _ in
                self?.applyToSelection { $0.straighten($1, strength: 1) }
            },
            UIAction(title: "글씨 다듬기", image: UIImage(systemName: "wand.and.stars")) { [weak self] _ in
                self?.applyToSelection { $0.correct($1, strength: 0.6) }
            },
            UIAction(title: "삭제", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
                self?.applyToSelection { $0.delete($1) }
                self?.clearSelection()
            },
        ])
    }

    private var lastLongPressPoint: CGPoint?

    @objc private func longPressed(_ g: UILongPressGestureRecognizer) {
        guard g.state == .began, model.app.strokeClipboard != nil else { return }
        lastLongPressPoint = g.location(in: contentView)
        editMenu?.presentEditMenu(with: UIEditMenuConfiguration(identifier: "paste" as NSString,
                                                                          sourcePoint: g.location(in: view)))
    }

    // MARK: Laser, text, images

    private func fadeLaser() {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.beginTime = CACurrentMediaTime() + 0.5
        fade.duration = 0.5
        fade.fillMode = .forwards
        fade.isRemovedOnCompletion = false
        laserLayer.add(fade, forKey: "fade")
    }

    private func addTextBox(at p: CGPoint, in pv: PageView) {
        let width = min(260.0, Double(pv.page.size.width) - Double(p.x) - 24)
        let element = PageElement(kind: .text, frame: ElementFrame(x: Double(p.x), y: Double(p.y) - 12,
                                                                     width: max(width, 80), height: 28),
                                  text: "", fontSize: 16, colorHex: tools.penColor)
        pendingFocus = element.id
        model.addElement(element, toPage: pv.pageID)
    }

    private func pickImage(at p: CGPoint, in pv: PageView) {
        pendingImagePoint = (pv.pageID, p)
        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = 1
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = self
        present(picker, animated: true)
    }

    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard let provider = results.first?.itemProvider, provider.canLoadObject(ofClass: UIImage.self),
              let target = pendingImagePoint else { return }
        let pageID = target.0, point = target.1
        provider.loadObject(ofClass: UIImage.self) { [weak self] object, _ in
            guard let image = object as? UIImage else { return }
            DispatchQueue.main.async {
                self?.model.addImage(image, toPage: pageID, center: point)
            }
        }
    }

    // MARK: Gestures

    @objc private func twoFingerTapped() { model.undo() }
    @objc private func threeFingerTapped() { model.redo() }

    func pencilInteractionDidTap(_ interaction: UIPencilInteraction) {
        switch UIPencilInteraction.preferredTapAction {
        case .ignore:
            return
        case .showColorPalette, .showInkAttributes:
            return
        default:
            if tools.tool == .eraser {
                model.tools.select(tools.lastInkTool)
            } else {
                model.tools.select(.eraser)
            }
            applySettings()
        }
    }

    // MARK: CanvasControlling

    func pagesDidChange() {
        clearSelection()
        for pv in pageViews.values { pv.removeFromSuperview() }
        pageViews.removeAll()
        relayout()
    }

    func inkDidChange(pageID: UUID, rect: CGRect) {
        guard let pv = pageViews[pageID] else { return }
        pv.invalidate(rect.isNull ? CGRect(x: 0, y: 0, width: pv.page.size.width, height: pv.page.size.height) : rect)
    }

    func elementsDidChange(pageID: UUID) {
        guard let pv = pageViews[pageID], let page = model.document.pages.first(where: { $0.id == pageID }) else { return }
        pv.updatePage(page)
        if let focus = pendingFocus, page.elements.contains(where: { $0.id == focus }) {
            pendingFocus = nil
            pv.beginEditing(elementID: focus)
        }
    }

    func scrollToPage(_ index: Int, animated: Bool) {
        guard pageFrames.indices.contains(index) else { return }
        let zoom = scrollView.zoomScale
        let y = max(0, pageFrames[index].minY * zoom - 16)
        let maxY = max(0, scrollView.contentSize.height - scrollView.bounds.height)
        scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: min(y, maxY)), animated: animated)
        updateVisiblePages()
    }

    func highlight(pageIndex: Int, rect: CGRect) {
        guard let page = model.document.pages[safe: pageIndex] else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.pageViews[page.id]?.flashHighlight(rect)
        }
    }
}

/// SwiftUI host for the canvas.
struct CanvasView: UIViewControllerRepresentable {
    @ObservedObject var model: EditorModel
    var settings: AppSettings

    func makeUIViewController(context: Context) -> CanvasViewController {
        CanvasViewController(model: model)
    }

    func updateUIViewController(_ controller: CanvasViewController, context: Context) {
        controller.applySettings()
    }
}
#endif
