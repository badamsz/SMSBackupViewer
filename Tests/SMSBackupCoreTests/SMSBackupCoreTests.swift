import XCTest
@testable import SMSBackupCore

final class SMSBackupCoreTests: XCTestCase {
    var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("smsbackup-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private func write(_ name: String, _ xml: String) throws -> URL {
        let url = tmp.appendingPathComponent(name)
        try xml.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testEntityDecoding() throws {
        let url = try write("sms.xml", """
        <?xml version='1.0' encoding='UTF-8' standalone='yes' ?>
        <!--File Created By SMS Backup & Restore-->
        <smses count="1">
          <sms address="+12075550100" date="1700000000000" type="1" body="Hi &#55357;&#56832; &amp; &quot;bye&quot;&#10;x&#1;y &#128512;" contact_name="Alex" subject="null" read="1" />
        </smses>
        """)
        var bodies: [String] = []
        try BackupParser(url: url).parse { rec in
            if case .sms(let s) = rec { bodies.append(s.body ?? "") }
        }
        XCTAssertEqual(bodies, ["Hi 😀 & \"bye\"\nxy 😀"])
    }

    func testSmallChunksAndMMS() throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3, 4]).base64EncodedString()
        let url = try write("mms.xml", """
        <smses>
          <mms date="1700000000000" msg_box="1" address="+12075550123~+12075550100" m_id="a1" contact_name="Sam, Alex">
            <parts>
              <part seq="-1" ct="application/smil" text="&lt;smil/&gt;" />
              <part seq="0" ct="image/png" name="pic.png" text="null" data="\(png)" />
              <part seq="1" ct="text/plain" text="Look &gt; this" />
            </parts>
            <addrs>
              <addr address="+12075550123" type="137" />
              <addr address="+12075550100" type="151" />
            </addrs>
          </mms>
        </smses>
        """)
        var mms: [MMSRecord] = []
        // Tiny chunk size exercises tag-spanning-chunk logic.
        try BackupParser(url: url, chunkSize: 7).parse { rec in
            if case .mms(let m) = rec { mms.append(m) }
        }
        XCTAssertEqual(mms.count, 1)
        XCTAssertEqual(mms[0].parts.count, 2)
        XCTAssertEqual(mms[0].parts[0].data?.count, 8)
        XCTAssertEqual(mms[0].parts[1].text, "Look > this")
        XCTAssertEqual(mms[0].addrs.count, 2)
    }

    func testImportDedupAndSearch() throws {
        let url = try write("sms-1.xml", """
        <smses>
          <sms address="+1 (207) 555-0100" date="1700000000000" type="1" body="Dinner at the lighthouse?" contact_name="Alex" />
          <sms address="2075550100" date="1700000060000" type="2" body="Sounds great" contact_name="Alex" />
          <sms address="2075550100" date="1700000060000" type="2" body="Sounds great" contact_name="Alex" />
        </smses>
        """)
        let store = try MessageStore(url: tmp.appendingPathComponent("db.sqlite"))
        let r1 = try store.importBackup(at: url)
        XCTAssertEqual(r1.messagesAdded, 2)
        XCTAssertEqual(r1.duplicatesSkipped, 1)
        let r2 = try store.importBackup(at: url)
        XCTAssertEqual(r2.messagesAdded, 0)

        let convs = try store.conversations()
        XCTAssertEqual(convs.count, 1)
        XCTAssertEqual(convs[0].displayName, "Alex")
        XCTAssertEqual(convs[0].messageCount, 2)

        let hits = try store.search(SearchQuery(text: "light"))
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits[0].message.senderName, "Alex")

        let filtered = try store.search(SearchQuery(contact: "555-0100", direction: .outgoing))
        XCTAssertEqual(filtered.count, 1)
    }

    func testZipImport() throws {
        let folder = tmp.appendingPathComponent("backup", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try """
        <smses><sms address="2075550100" date="1700000000000" type="1" body="zipped hello" contact_name="Alex" /></smses>
        """.write(to: folder.appendingPathComponent("sms-1.xml"), atomically: true, encoding: .utf8)
        try """
        <calls><call number="2075550100" duration="60" date="1700000000000" type="1" contact_name="Alex" /></calls>
        """.write(to: folder.appendingPathComponent("calls-1.xml"), atomically: true, encoding: .utf8)
        try "ignore me".write(to: folder.appendingPathComponent("readme.txt"), atomically: true, encoding: .utf8)

        let zip = tmp.appendingPathComponent("backup.zip")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-c", "-k", "--keepParent", folder.path, zip.path]
        try p.run()
        p.waitUntilExit()
        XCTAssertTrue(BackupArchive.isZip(zip))

        let store = try MessageStore(url: tmp.appendingPathComponent("db.sqlite"))
        let results = try store.importFile(at: zip)
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results.reduce(0) { $0 + $1.messagesAdded }, 1)
        XCTAssertEqual(results.reduce(0) { $0 + $1.callsAdded }, 1)
        XCTAssertEqual(try store.search(SearchQuery(text: "zipped")).count, 1)
    }

    func testFTSQuery() {
        XCTAssertEqual(MessageStore.ftsQuery("hello wor"), "\"hello\"* \"wor\"*")
        XCTAssertEqual(MessageStore.ftsQuery("\"see you\" soon"), "\"see you\" \"soon\"*")
        XCTAssertNil(MessageStore.ftsQuery("   "))
    }

    func testPhoneKey() {
        XCTAssertEqual(PhoneNumber.key("+1 (207) 555-0100"), "2075550100")
        XCTAssertEqual(PhoneNumber.key("2075550100"), "2075550100")
        XCTAssertEqual(PhoneNumber.key("Me@Example.com"), "me@example.com")
        XCTAssertEqual(PhoneNumber.key("72975"), "72975")
    }
}
