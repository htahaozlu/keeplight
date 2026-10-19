import AppKit
import Testing
@testable import KeeplightUI

/// The panel is one surface: the window's shape (from the content view's `maskImage`), the opaque
/// fill, the hairline and the clip of the content all come from `PanelShape`, so the corners
/// cannot disagree. These check the real container `PanelController` installs, in a borderless
/// window that is never ordered in.
@MainActor
@Suite("Panel surface")
struct PanelSurfaceTests {
    private func mounted(opaque: Bool, size: CGSize = CGSize(width: Metrics.panelWidth, height: 300))
        -> (NSWindow, PanelSurfaceView) {
        let window = NSWindow(contentRect: NSRect(x: -40_000, y: -40_000, width: size.width, height: size.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.isReleasedWhenClosed = false
        let surface = PanelMaterial.container(wrapping: NSView(), opaque: opaque)
        window.contentView = surface
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        return (window, surface)
    }

    @Test(arguments: [false, true])
    func theWindowsContentViewDeclaresTheRoundedShape(opaque: Bool) throws {
        let (window, surface) = mounted(opaque: opaque)
        // AppKit shapes a borderless window (and its shadow) only from the mask image of a
        // visual effect view that is the window's content view.
        let content = try #require(window.contentView as? NSVisualEffectView)
        let mask = try #require(content.maskImage)
        let r = Metrics.panelRadius
        #expect(mask.capInsets.top == r && mask.capInsets.left == r && mask.capInsets.bottom == r
            && mask.capInsets.right == r)
        #expect(mask.size == NSSize(width: 2 * r + 1, height: 2 * r + 1))
        #expect(surface.shape.radius == r)
    }

    @Test(arguments: [false, true])
    func theContentIsClippedToTheSameShape(opaque: Bool) throws {
        let (_, surface) = mounted(opaque: opaque)
        #expect(surface.content.superview === surface.clip)
        #expect(surface.clip.frame == surface.bounds)
        let path = try #require(surface.clip.maskPath)
        #expect(path == surface.shape.path(in: surface.bounds))
    }

    @Test func theOpaqueFillAndHairlineFollowTheShape() throws {
        let (_, surface) = mounted(opaque: true)
        #expect(surface.isOpaqueSurface)
        let fill = try #require(surface.fill.shapeLayer)
        #expect(fill.path == surface.shape.path(in: surface.bounds))
        #expect(fill.fillColor != nil)
        let hairline = try #require(surface.hairline.shapeLayer)
        let width = ShapeView.hairlineWidth
        #expect(hairline.path == surface.shape.hairlinePath(in: surface.bounds, width: width))
        // The stroke lies wholly inside the outline: its outer edge is the shape itself.
        let outer = try #require(hairline.path).boundingBoxOfPath.insetBy(dx: -width / 2, dy: -width / 2)
        #expect(outer == surface.bounds)
        // Back to front: fill, content, hairline.
        #expect(surface.subviews.map(ObjectIdentifier.init)
            == [surface.fill, surface.clip, surface.hairline].map(ObjectIdentifier.init))
    }

    @Test func theMaterialSurfaceDrawsNoFillOrHairline() {
        let (_, surface) = mounted(opaque: false)
        #expect(!surface.isOpaqueSurface)
        #expect(surface.fill.isHidden && surface.hairline.isHidden)
    }

    @Test func aResizeKeepsEveryLayerOnTheShape() throws {
        let (window, surface) = mounted(opaque: true)
        window.setContentSize(NSSize(width: Metrics.panelWidth, height: 520))
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let bounds = surface.bounds
        #expect(bounds.height == 520)
        #expect(surface.clip.maskPath == surface.shape.path(in: bounds))
        #expect(surface.fill.shapeLayer?.path == surface.shape.path(in: bounds))
    }

    @Test func theContentGetsThePlainAppearanceNotTheVibrantOne() {
        let (window, surface) = mounted(opaque: false)
        window.appearance = NSAppearance(named: .darkAqua)
        surface.viewDidChangeEffectiveAppearance()
        #expect(surface.clip.appearance?.name == .darkAqua)
        window.appearance = NSAppearance(named: .aqua)
        surface.viewDidChangeEffectiveAppearance()
        #expect(surface.clip.appearance?.name == .aqua)
    }

    @Test func theShapeClampsItsRadiusToHalfTheShortSide() {
        let shape = PanelShape(radius: 18)
        let small = CGRect(x: 0, y: 0, width: 20, height: 10)
        #expect(shape.path(in: small) == CGPath(roundedRect: small, cornerWidth: 5, cornerHeight: 5, transform: nil))
    }
}
