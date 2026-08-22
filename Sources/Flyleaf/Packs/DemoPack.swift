import Foundation

// Canned content used by "flyleaf://demo" and by onboarding screenshots.
// Exercises every card type without needing Amazon or an API key. Images are
// resolved live from Wikipedia so the enrichment path gets exercised too.
enum DemoPack {
    static let book = BookRef(
        asin: "demo:apple-in-china",
        title: "Apple in China",
        authors: ["Patrick McGee"],
        coverURL: nil,
        isManual: true
    )

    static let toc = BookTOC(
        chapters: [
            TOCChapter(index: 1, title: "The Deal of the Century", startPercent: 2),
            TOCChapter(index: 2, title: "Outsourcing Everything", startPercent: 11),
            TOCChapter(index: 3, title: "iPhone City", startPercent: 21),
            TOCChapter(index: 4, title: "The Squeeze", startPercent: 33),
            TOCChapter(index: 5, title: "Red Supply Chain", startPercent: 45),
            TOCChapter(index: 6, title: "Entanglement", startPercent: 58),
            TOCChapter(index: 7, title: "Decoupling Dreams", startPercent: 71),
            TOCChapter(index: 8, title: "Exit Strategies", startPercent: 84),
        ],
        source: "demo"
    )

    static func pack() -> ContextPack {
        ContextPack(
            asin: book.asin,
            chapter: 3,
            chapterTitle: "iPhone City",
            packVersion: ContextPack.currentVersion,
            briefing: "Apple's manufacturing bet lands in Zhengzhou, where a purpose-built campus begins assembling iPhones at unprecedented scale. Terry Gou's Foxconn supplies the discipline and the workforce. The chapter follows how a provincial capital became the center of the hardware world.",
            entities: [
                Entity(
                    kind: .person,
                    name: "Terry Gou",
                    oneLiner: "Founder of Foxconn, the Taiwanese giant that assembles most iPhones.",
                    detail: "Gou built Foxconn from a plastics shop into the world's largest contract manufacturer, and personally negotiated the subsidies behind the Zhengzhou campus.",
                    wikipediaTitle: "Terry Gou",
                    imageURL: nil,
                    latitude: nil,
                    longitude: nil,
                    firstMentionChapter: 2,
                    affiliation: "Foxconn",
                    pronunciation: "TEH-ree GWOH",
                    thenNow: nil,
                    sourceURLs: [URL(string: "https://en.wikipedia.org/wiki/Terry_Gou")!],
                    rank: 1,
                    dateText: nil,
                    sortDate: nil
                ),
                Entity(
                    kind: .place,
                    name: "Zhengzhou",
                    oneLiner: "Capital of Henan province and home of the iPhone City campus.",
                    detail: "A city of ten million on the Yellow River plain. Its airport economic zone was rebuilt around a single customer: Apple.",
                    wikipediaTitle: "Zhengzhou",
                    imageURL: nil,
                    latitude: 34.7466,
                    longitude: 113.6253,
                    firstMentionChapter: 3,
                    affiliation: nil,
                    pronunciation: "jung-JOH",
                    thenNow: nil,
                    sourceURLs: [URL(string: "https://en.wikipedia.org/wiki/Zhengzhou")!],
                    rank: 2,
                    dateText: nil,
                    sortDate: nil
                ),
                Entity(
                    kind: .product,
                    name: "iPod Mini",
                    oneLiner: "The 2004 anodized aluminum player that taught Apple mass metalwork.",
                    detail: "Its clamshell of colored aluminum forced Apple and its suppliers to master finishes at scale, a skill that later defined the iPhone.",
                    wikipediaTitle: "IPod Mini",
                    imageURL: nil,
                    latitude: nil,
                    longitude: nil,
                    firstMentionChapter: 1,
                    affiliation: nil,
                    pronunciation: nil,
                    thenNow: "$249 in 2004 is about $415 today.",
                    sourceURLs: [URL(string: "https://en.wikipedia.org/wiki/IPod_Mini")!],
                    rank: 3,
                    dateText: nil,
                    sortDate: nil
                ),
                Entity(
                    kind: .organization,
                    name: "Foxconn",
                    oneLiner: "Taiwanese contract manufacturer running the Zhengzhou lines.",
                    detail: "Formally Hon Hai Precision Industry. Employs hundreds of thousands in Zhengzhou during peak iPhone season.",
                    wikipediaTitle: "Foxconn",
                    imageURL: nil,
                    latitude: nil,
                    longitude: nil,
                    firstMentionChapter: 1,
                    affiliation: nil,
                    pronunciation: nil,
                    thenNow: nil,
                    sourceURLs: [URL(string: "https://en.wikipedia.org/wiki/Foxconn")!],
                    rank: 4,
                    dateText: nil,
                    sortDate: nil
                ),
                Entity(
                    kind: .term,
                    name: "Bonded zone",
                    oneLiner: "A customs area where parts arrive and exports leave without formally entering China.",
                    detail: "Zhengzhou's bonded zone let iPhones be built in China yet counted as imports and exports at the factory gate, a customs trick central to the campus design.",
                    wikipediaTitle: "Free-trade zone",
                    imageURL: nil,
                    latitude: nil,
                    longitude: nil,
                    firstMentionChapter: 3,
                    affiliation: nil,
                    pronunciation: nil,
                    thenNow: nil,
                    sourceURLs: [URL(string: "https://en.wikipedia.org/wiki/Free-trade_zone")!],
                    rank: 5,
                    dateText: nil,
                    sortDate: nil
                ),
                Entity(
                    kind: .event,
                    name: "Zhengzhou campus opens",
                    oneLiner: "Foxconn's Zhengzhou plant ships its first iPhones.",
                    detail: nil,
                    wikipediaTitle: nil,
                    imageURL: nil,
                    latitude: nil,
                    longitude: nil,
                    firstMentionChapter: 3,
                    affiliation: nil,
                    pronunciation: nil,
                    thenNow: nil,
                    sourceURLs: [],
                    rank: 6,
                    dateText: "August 2010",
                    sortDate: "2010-08-01"
                ),
            ],
            builtAt: Date()
        )
    }
}
