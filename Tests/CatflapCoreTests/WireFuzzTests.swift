import CatflapCore
import Foundation
import Testing

@Suite struct WireFuzzTests {
    @Test func testDecoderSurvivesTenThousandRandomFrames() throws {
        var random = SystemRandomNumberGenerator()
        for index in 0..<10_000 {
            var decoder = FrameDecoder()
            if index % 10 == 0 {
                let offer = TransferOffer(id: String(index), kind: "text", name: "text", size: 0, mime: "text/plain")
                let frame = try WireCodec.frame(offer)
                for byte in frame { decoder.append(Data([byte])) }
                #expect(try decoder.next()?.decode(TransferOffer.self).id == String(index))
                #expect(try decoder.next() == nil)
            } else {
                let count = Int.random(in: 0...256, using: &random)
                let bytes = Data((0..<count).map { _ in UInt8.random(in: 0...255, using: &random) })
                decoder.append(bytes)
                do { _ = try decoder.next() }
                catch let error as WireError { #expect([.emptyFrame, .frameTooLarge, .malformed].contains(error)) }
                #expect(decoder.bufferedCount <= 256)
            }
        }
        var decoder = FrameDecoder(); decoder.append(Data([0, 1, 0, 1]))
        #expect(throws: WireError.frameTooLarge) { try decoder.next() }
    }
}
