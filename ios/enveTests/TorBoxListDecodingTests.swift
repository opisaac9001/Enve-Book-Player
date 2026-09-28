import Foundation
import Testing

@testable import enve

// Shapes follow TorBox's official SDK (torbox-sdk-py) list models; no live TorBox account is available to capture from.
@MainActor
struct TorBoxListDecodingTests {
    @Test(arguments: ["torrents", "usenet", "webdl"])
    func decodesSDKListShape(_ kind: String) throws {
        let json = #"""
        {"success":true,"error":null,"detail":"Items fetched.","data":[
          {"id":4211,"auth_id":"a","hash":"0f1e2d","name":"The Hobbit","size":734003200,"active":false,
           "download_present":true,"download_finished":true,"progress":1,
           "files":[
             {"id":0,"md5":null,"mimetype":"audio/mpeg","name":"The Hobbit/01 - An Unexpected Party.mp3",
              "s3_path":"0f1e2d/The Hobbit/01 - An Unexpected Party.mp3","short_name":"01 - An Unexpected Party.mp3","size":52428800},
             {"id":1,"md5":"9a","mimetype":"image/jpeg","name":"The Hobbit/cover.jpg",
              "s3_path":"0f1e2d/The Hobbit/cover.jpg","short_name":"cover.jpg","size":204800}
           ]},
          {"id":4212,"hash":"aa11","name":"Pending","size":0,"download_present":false,"download_finished":false,"files":[]}
        ]}
        """#
        let downloads = try #require(try JSONDecoder().decode(WebDAVProvider.TorBoxListResponse.self, from: Data(json.utf8)).data)
        #expect(downloads.rejectedItems.isEmpty, "\(kind)")
        #expect(downloads.values.map(\.id) == [4211, 4212])

        let ready = downloads.values[0]
        #expect(ready.isAvailable)
        #expect(ready.hash == "0f1e2d")
        #expect(ready.name == "The Hobbit")
        #expect(ready.size == 734_003_200)
        let files = try #require(ready.files?.values)
        #expect(files.map(\.id) == [0, 1])
        #expect(files[0].shortName == "01 - An Unexpected Party.mp3")
        #expect(files[0].name == "The Hobbit/01 - An Unexpected Party.mp3")
        #expect(files[0].s3Path == "0f1e2d/The Hobbit/01 - An Unexpected Party.mp3")
        #expect(files[0].size == 52_428_800)

        #expect(!downloads.values[1].isAvailable)
    }

    @Test func malformedEntriesAreRejectedIndividually() throws {
        let json = #"""
        {"data":[{"id":"not-a-number","name":"Broken"},
                 {"id":7,"name":"Loose","files":[{"id":"x"},{"id":3,"short_name":"a.m4b"}]}]}
        """#
        let downloads = try #require(try JSONDecoder().decode(WebDAVProvider.TorBoxListResponse.self, from: Data(json.utf8)).data)
        #expect(downloads.values.map(\.id) == [7])
        #expect(downloads.rejectedItems.count == 1)
        #expect(downloads.values[0].isAvailable)
        #expect(downloads.values[0].files?.values.map(\.id) == [3])
    }

    @Test func errorResponseWithNullDataDecodes() throws {
        let json = #"{"success":false,"error":"BAD_TOKEN","detail":"Invalid token.","data":null}"#
        #expect(try JSONDecoder().decode(WebDAVProvider.TorBoxListResponse.self, from: Data(json.utf8)).data == nil)
    }
}
