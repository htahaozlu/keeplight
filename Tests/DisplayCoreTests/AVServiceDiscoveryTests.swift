import CoreGraphics
import Foundation
import Testing
@testable import DisplayCore

private var fbInternal: AVServiceDiscovery.Framebuffer { .init(path: "IOService:/a/disp0@7C000000/AppleCLCD2", attributes: [:]) }
private var fbExt0: AVServiceDiscovery.Framebuffer { .init(path: "IOService:/a/dispext0@8000000/AppleCLCD2", attributes: [:]) }
private var fbExt1: AVServiceDiscovery.Framebuffer { .init(path: "IOService:/a/dispext1@9000000/AppleCLCD2", attributes: [:]) }

@Test func pairsProxyByFramebufferNode() {
    let fbs = [fbInternal, fbExt0, fbExt1]
    let proxy1 = "IOService:/a/dcpext1@B0/x/dispext1:dcpav-service-epic:0/DCPAVServiceProxy"
    let proxy0 = "IOService:/a/dcpext@AC/x/dispext0:dcpav-service-epic:0/DCPAVServiceProxy"
    // Enumeration order would pair both proxies with dispext1; the node name decides.
    #expect(AVServiceDiscovery.framebuffer(forProxyAt: proxy0, in: fbs, preceding: 3)?.path == fbExt0.path)
    #expect(AVServiceDiscovery.framebuffer(forProxyAt: proxy1, in: fbs, preceding: 3)?.path == fbExt1.path)
}

@Test func fallsBackToPrecedingFramebuffer() {
    let fbs = [fbInternal, fbExt0]
    #expect(AVServiceDiscovery.framebuffer(forProxyAt: "IOService:/a/other/DCPAVServiceProxy", in: fbs, preceding: 2)?.path == fbExt0.path)
    #expect(AVServiceDiscovery.framebuffer(forProxyAt: nil, in: fbs, preceding: 0) == nil)
}

private func display(vendor: UInt32, product: UInt32, serial: UInt32, name: String = "U2723QE") -> DisplayInfo {
    DisplayInfo(id: 7, name: name, vendorID: vendor, productID: product, serialNumber: serial, uuid: nil,
                isBuiltin: false, isMain: false, isActive: true, isOnline: true, mirrorSource: nil,
                bounds: .zero, rotation: 0, currentMode: nil)
}

private func service(product: Int, serial: Int) -> AVServiceEntry {
    AVServiceEntry(service: "stub" as CFString, manufacturerID: "DEL", productID: product,
                   serialNumber: serial, productName: "DELL U2723QE", framebufferPath: nil)
}

@Test func scoresAndDisqualifiesBySerial() {
    let del = AVServiceDiscovery.pnpCode("DEL")!
    #expect(AVServiceDiscovery.score(display(vendor: del, product: 0x4242, serial: 111), service(product: 0x4242, serial: 111)) == 11)
    #expect(AVServiceDiscovery.score(display(vendor: del, product: 0x4242, serial: 0), service(product: 0x4242, serial: 111)) == 9)
    #expect(AVServiceDiscovery.score(display(vendor: del, product: 0x4242, serial: 222), service(product: 0x4242, serial: 111)) == nil)
    #expect(AVServiceDiscovery.score(display(vendor: del, product: 0x1111, serial: 0), service(product: 0x4242, serial: 0))! < 8)
}
