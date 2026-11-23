#if canImport(UIKit) && DEBUG
import NoteKit
import SwiftUI
import UIKit

/// Debug-only sample library for screenshots and simulator checks.
/// Launch with `-NoteDemoScreen library|editor|pdf|connect|settings`.
enum DemoContent {
    static var requestedScreen: String? {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-NoteDemoScreen"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    @MainActor
    static func seed(_ app: AppModel) {
        let lib = app.library(.local)
        guard (try? lib.list("/"))?.contains(where: { $0.kind == .notebook }) != true else { return }
        for folder in ["강의자료", "연구노트", "회의록"] { _ = try? lib.createFolder(named: folder, in: "/") }

        let ruled = PaperStyle(template: .ruled)
        var linear = NotebookDocument(title: "선형대수 필기", cover: CoverStyle(colorHex: "#2F5BD3"), paper: ruled,
                                      pageCount: 4)
        linear.pages[0].elements = [
            PageElement(kind: .text, frame: ElementFrame(x: 84, y: 70, width: 420, height: 34),
                        text: "7주차 · 고유값과 고유벡터", fontSize: 24, colorHex: "#1C1C1E"),
            PageElement(kind: .text, frame: ElementFrame(x: 84, y: 130, width: 420, height: 90),
                        text: "정의: A v = λ v (v ≠ 0)\n특성방정식 det(A − λI) = 0\ntr(A) = Σ λᵢ, det(A) = Π λᵢ",
                        fontSize: 17, colorHex: "#1F4FD1"),
        ]
        linear.pages[1].bookmarked = true
        _ = try? NotebookPackage.create(in: lib.root, document: linear)
        _ = try? NotebookPackage.create(in: lib.root, document: NotebookDocument(
            title: "물리 실험 보고서", cover: CoverStyle(colorHex: "#1F7A55"), paper: PaperStyle(template: .grid), pageCount: 9))
        _ = try? NotebookPackage.create(in: lib.root, document: NotebookDocument(
            title: "알고리즘 스터디", cover: CoverStyle(colorHex: "#2B2F38"), paper: PaperStyle(template: .dotted), pageCount: 3))
        _ = try? NotebookPackage.create(in: lib.root, document: NotebookDocument(
            title: "빠른 메모", cover: CoverStyle(colorHex: nil), paper: PaperStyle(template: .cornell), pageCount: 2))
        if let pdf = makeSamplePDF() {
            _ = try? lib.importFile(from: pdf, into: "/", preferredName: "운영체제_09강_CPU스케줄링.pdf")
        }
        app.refreshLibrary()
    }

    /// A small lecture-notes PDF with an outline-worthy structure.
    static func makeSamplePDF() -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("demo.pdf")
        let bounds = CGRect(x: 0, y: 0, width: 595, height: 842)
        let renderer = UIGraphicsPDFRenderer(bounds: bounds)
        let sections = ["3.1 FCFS", "3.2 SJF", "3.3 Round Robin"]
        let body = "RR은 각 프로세스에 작은 단위의 CPU 시간(타임 퀀텀)을 할당한다. 퀀텀이 지나면 프로세스는 선점되어 "
            + "준비 큐의 끝으로 이동한다. n개의 프로세스가 있고 퀀텀이 q이면, 어떤 프로세스도 (n − 1) × q 시간 이상 "
            + "기다리지 않는다. 성능은 타임 퀀텀의 크기에 크게 좌우된다."
        do {
            try renderer.writePDF(to: url) { ctx in
                for (i, title) in sections.enumerated() {
                    ctx.beginPage()
                    ("CHAPTER 3 · CPU SCHEDULING" as NSString).draw(at: CGPoint(x: 52, y: 48), withAttributes: [
                        .font: UIFont.systemFont(ofSize: 11), .foregroundColor: UIColor.darkGray])
                    (title as NSString).draw(at: CGPoint(x: 52, y: 70), withAttributes: [
                        .font: UIFont.boldSystemFont(ofSize: 22)])
                    (body as NSString).draw(in: CGRect(x: 52, y: 120, width: 490, height: 300), withAttributes: [
                        .font: UIFont.systemFont(ofSize: 13)])
                    UIColor(white: 0.92, alpha: 1).setFill()
                    UIRectFill(CGRect(x: 52, y: 330, width: 490, height: 120))
                    ("그림 3.\(i + 5)" as NSString).draw(at: CGPoint(x: 270, y: 460), withAttributes: [
                        .font: UIFont.systemFont(ofSize: 11)])
                }
            }
            return url
        } catch {
            return nil
        }
    }
}
#endif
