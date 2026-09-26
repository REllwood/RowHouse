import Foundation
import Testing
@testable import RowHouseCore

@Suite("Excel import")
struct XLSXReaderTests {
    func writeWorkbook(date1904: Bool = false) throws -> URL {
        let dir = TestSupport.tempDirectory().appendingPathComponent("book", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: dir.appendingPathComponent("xl/_rels"), withIntermediateDirectories: true)
        try fm.createDirectory(at: dir.appendingPathComponent("xl/worksheets"), withIntermediateDirectories: true)
        func write(_ path: String, _ xml: String) throws { try Data(xml.utf8).write(to: dir.appendingPathComponent(path)) }
        try write("xl/workbook.xml", """
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
          <workbookPr\(date1904 ? " date1904=\"1\"" : "")/>
          <sheets><sheet name="Deals" sheetId="1" r:id="rId1"/><sheet name="Empty" sheetId="2" r:id="rId2"/></sheets>
        </workbook>
        """)
        try write("xl/_rels/workbook.xml.rels", """
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
          <Relationship Id="rId1" Type="worksheet" Target="worksheets/sheet1.xml"/>
          <Relationship Id="rId2" Type="worksheet" Target="/xl/worksheets/sheet2.xml"/>
        </Relationships>
        """)
        try write("xl/sharedStrings.xml", """
        <sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><si><t>Name</t></si><si><t>Close</t></si><si><r><t>Acme </t></r><r><t>Corp</t></r></si><si><t>Won</t></si></sst>
        """)
        try write("xl/styles.xml", """
        <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
          <numFmts count="1"><numFmt numFmtId="164" formatCode="dd/mm/yyyy"/></numFmts>
          <cellXfs count="3"><xf numFmtId="0"/><xf numFmtId="164"/><xf numFmtId="22"/></cellXfs>
        </styleSheet>
        """)
        try write("xl/worksheets/sheet1.xml", """
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>
          <row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1" t="s"><v>1</v></c><c r="C1" t="inlineStr"><is><t>Paid</t></is></c><c r="D1" t="str"><v>Amount</v></c></row>
          <row r="2"><c r="A2" t="s"><v>2</v></c><c r="B2" s="1"><v>46291</v></c><c r="C2" t="b"><v>1</v></c><c r="D2"><v>1250.5</v></c></row>
          <row r="4"><c r="A4" t="s"><v>3</v></c><c r="C4" t="b"><v>0</v></c><c r="D4" s="2"><v>46291.5</v></c></row>
        </sheetData></worksheet>
        """)
        try write("xl/worksheets/sheet2.xml", "<worksheet><sheetData/></worksheet>")
        return dir
    }

    @Test func readsSharedStringsDatesBooleansAndGaps() throws {
        let sheets = try XLSXReader.read(unzippedAt: try writeWorkbook())
        #expect(sheets.map(\.name) == ["Deals", "Empty"])
        #expect(sheets[0].rows == [
            ["Name", "Close", "Paid", "Amount"],
            ["Acme Corp", "2026-09-26", "true", "1250.5"],
            ["", "", "", ""],
            ["Won", "", "false", "2026-09-26 12:00"],
        ])
        #expect(sheets[1].rows.isEmpty)
    }

    @Test func readsZippedWorkbooks() throws {
        let dir = try writeWorkbook()
        let xlsx = dir.deletingLastPathComponent().appendingPathComponent("book.xlsx")
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        zip.arguments = ["-c", "-k", dir.path, xlsx.path]
        try zip.run()
        zip.waitUntilExit()
        let sheets = try XLSXReader.read(xlsx)
        #expect(sheets.first?.rows.count == 4)
        #expect(throws: (any Error).self) { try XLSXReader.read(dir.appendingPathComponent("xl/workbook.xml")) }
    }

    @Test func columnLettersAndSerialDates() {
        #expect(XLSXReader.columnIndex("A1") == 0)
        #expect(XLSXReader.columnIndex("Z9") == 25)
        #expect(XLSXReader.columnIndex("AA10") == 26)
        #expect(XLSXReader.excelDate(1, date1904: true) == "1904-01-02")
        #expect(XLSXReader.excelDate(45658, date1904: false) == "2025-01-01")
    }
}
