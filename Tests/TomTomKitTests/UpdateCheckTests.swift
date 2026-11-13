import Foundation
import Testing
@testable import TomTomKit

@Suite struct UpdateCheckTests {
    @Test func comparesVersions() {
        #expect(UpdateCheck.isNewer("0.2.0", than: "0.1.0"))
        #expect(UpdateCheck.isNewer("0.10.0", than: "0.9.1"))
        #expect(UpdateCheck.isNewer("v1.0", than: "0.9.9"))
        #expect(UpdateCheck.isNewer("0.1.1", than: "0.1"))
        #expect(!UpdateCheck.isNewer("0.1.0", than: "0.1.0"))
        #expect(!UpdateCheck.isNewer("0.1.0", than: "0.1.0-3-gabc123"))
        #expect(!UpdateCheck.isNewer("0.1.0", than: "0.2.0"))
    }

    @Test func parsesLatestRelease() throws {
        let json = #"{"tag_name":"v0.2.0","html_url":"https://github.com/dzgnnl/TomTomSync/releases/tag/v0.2.0","name":"x"}"#
        let r = try UpdateCheck.parse(Data(json.utf8))
        #expect(r.version == "0.2.0")
        #expect(r.url.absoluteString.hasSuffix("/v0.2.0"))
    }
}

@Suite struct UpdateCheckParsingTests {
    @Test func buildsTheLinkItself() throws {
        let json = #"{"tag_name":"v0.2.0","html_url":"file:///etc/passwd"}"#
        let r = try UpdateCheck.parse(Data(json.utf8))
        #expect(r.url.absoluteString == "https://github.com/dzgnnl/TomTomSync/releases/tag/v0.2.0")
    }

    @Test func rejectsATagThatIsNotAVersion() {
        for tag in ["v1.0; rm -rf", "latest", "", "v1.0\n2", "1.0/../x"] {
            let json = try! JSONSerialization.data(withJSONObject: ["tag_name": tag])
            #expect(throws: (any Error).self) { try UpdateCheck.parse(json) }
        }
    }
}
