import Foundation

/// Fixed multi-label topic space shared with the Jev service.
enum JevPersona {
    static let version = "jev-topics-v1"
    static let threshold = 0.15
    static let topics: [String] = ["Machine learning","Local AI","AI agents","AI safety","AI ethics","Robotics","Computer vision","Natural language processing","AI research","AI in education","AI in healthcare","AI creative tools","AI hardware","Open source AI","Automation","Human AI interaction","Data engineering","Data analytics","Data visualization","Databases","Data quality","Data privacy","Statistics","Forecasting","Causal inference","Experiment design","Business intelligence","Geospatial data","Time series","Data governance","Scientific computing","Knowledge management","Software engineering","Mobile apps","Web development","Programming languages","Open source software","Cybersecurity","Cloud computing","Distributed systems","Computer networks","Developer tools","User experience design","Digital accessibility","Decentralized social networks","Personal computing","Electronics","Computer architecture","Mathematics","Physics","Chemistry","Biology","Astronomy","Neuroscience","Cognitive science","Earth science","Materials science","Mechanical engineering","Civil engineering","Aerospace","Scientific methods","Science communication","History of science","Emerging technology","Electricity grids","Renewable energy","Energy storage","Energy markets","Nuclear energy","Energy efficiency","Climate science","Climate adaptation","Climate policy","Carbon removal","Water systems","Biodiversity","Conservation","Circular economy","Sustainable transport","Urban sustainability","Entrepreneurship","Social enterprise","Cooperatives","Nonprofit organizations","Gift economy","Economic inequality","Public goods","Development economics","Behavioral economics","Labor economics","International trade","Macroeconomics","Business strategy","Product management","Ethical business","Community finance","Vegetarian cooking","Vegan cooking","Home cooking","Baking","Food science","Sustainable agriculture","Organic farming","Community gardens","Food security","Food distribution","Food waste","Local food systems","Fermentation","Coffee and tea","Regional cuisines","Food cooperatives","Exercise","Strength training","Walking and hiking","Cycling","Running","Yoga","Sleep","Nutrition","Preventive health","Mental wellbeing","Stress management","Healthy aging","Rehabilitation","Public health","Healthcare systems","Medical research","Parenting","Child development","Infant care","Child nutrition","Family relationships","Partnership","Friendship","Caregiving","Communication skills","Conflict resolution","Community building","Volunteering","Social connection","Family traditions","Work life balance","Intergenerational relationships","Meditation","Mindfulness","Buddhist philosophy","Indian philosophy","Western philosophy","Ethics","Philosophy of mind","Consciousness","Spiritual practice","Comparative religion","Meaning and purpose","Self reflection","Compassion","Personal values","Critical thinking","Philosophy of technology","Learning methods","Language learning","Early childhood education","School education","Higher education","Vocational education","Teaching","Educational technology","Lifelong learning","Reading and books","Writing","Public speaking","Research careers","Career development","Leadership","Team collaboration","Literature","Poetry","Music","Film","Photography","Visual art","Architecture","Graphic design","Fashion and textiles","Crafts","Theater","Dance","Museums","Cultural heritage","History","Storytelling","Travel","Slow travel","Family travel","Workation","Nature tourism","Public transport","Rail travel","Local exploration","Migration and belonging","Multilingual life","Housing","Home improvement","Minimalism","Personal organization","Time management","Digital wellbeing","Democracy","Civic participation","Public policy","Human rights","Social justice","Peace and conflict","International relations","Local government","Media literacy","Journalism","Digital rights","Consumer rights","Personal finance","Financial literacy","Sports","Games"]
    struct Record: Codable {
        let fingerprint: String
        let date: Date
        let scores: [Double]
    }
    struct Cache: Codable {
        var version = JevPersona.version
        var journals: [String: Record] = [:]
        var content: [String: [Double]] = [:]
        static var url: URL {
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("jev-persona-v1.json")
        }
        static func load() -> Cache {
            guard let cache = try? JSONDecoder().decode(Cache.self, from: Data(contentsOf: url)),
                  cache.version == JevPersona.version,
                  cache.journals.values.allSatisfy({ valid($0.scores) }),
                  cache.content.values.allSatisfy({ valid($0) }) else { return Cache() }
            return cache
        }
        func save() throws {
            try FileManager.default.createDirectory(at: Self.url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(self).write(to: Self.url, options: [.atomic, .completeFileProtection])
        }
    }
    static func valid(_ scores: [Double]) -> Bool {
        scores.count == topics.count && scores.allSatisfy { $0.isFinite && (0...1).contains($0) }
    }
    /// Suppress weak associations before summing. Each journal contributes
    /// once, with a 90-day half-life; edits replace rather than double-count.
    static func vector(_ records: [Record], now: Date = Date()) -> [Double] {
        var weights = Array(repeating: 0.0, count: topics.count)
        for record in records where valid(record.scores) {
            let decay = pow(0.5, max(0, now.timeIntervalSince(record.date)) / (90 * 86400))
            for i in weights.indices { weights[i] += evidence(record.scores[i]) * decay }
        }
        return weights
    }
    static func evidence(_ value: Double) -> Double { max(0, (value - 0.5) * 2) }
    /// Compare topic share in the last seven days with the seven before.
    /// No baseline is different from stable. Ignore future-dated journals.
    static func trends(_ records: [Record], now: Date = Date()) -> [String: String] {
        let week: TimeInterval = 7 * 86400
        let recent = records.filter { valid($0.scores) && (0..<week).contains(now.timeIntervalSince($0.date)) }
        let prior = records.filter { valid($0.scores) && (week..<(2 * week)).contains(now.timeIntervalSince($0.date)) }
        guard !recent.isEmpty, !prior.isEmpty else { return [:] }
        func shares(_ entries: [Record]) -> [Double] {
            var values = Array(repeating: 0.0, count: topics.count)
            for entry in entries { for i in values.indices { values[i] += evidence(entry.scores[i]) } }
            let total = values.reduce(0, +)
            return total > 0 ? values.map { $0 / total } : []
        }
        let a = shares(recent), b = shares(prior)
        guard a.count == topics.count, b.count == topics.count else { return [:] }
        var result: [String: String] = [:]
        for i in topics.indices {
            let delta = a[i] - b[i]
            result[topics[i]] = delta > 0.01 ? "↑" : delta < -0.01 ? "↓" : "→"
        }
        return result
    }
    /// Cosine similarity is a dot product after unit-length normalization.
    /// This is a ranking score, never a calibrated probability of interest.
    static func similarity(_ weights: [Double], _ scores: [Double]) -> Double {
        guard weights.count == topics.count, valid(scores) else { return 0 }
        let content = scores.map(evidence)
        let norm = sqrt(weights.reduce(0) { $0 + $1 * $1 } * content.reduce(0) { $0 + $1 * $1 })
        guard norm > 0 else { return 0 }
        return min(1, max(0, zip(weights, content).reduce(0) { $0 + $1.0 * $1.1 } / norm))
    }
    static func explanation(_ weights: [Double], _ scores: [Double]) -> String {
        guard weights.count == topics.count, valid(scores) else { return "" }
        return weights.indices.filter { weights[$0] * evidence(scores[$0]) > 0 }
            .sorted { weights[$0] * evidence(scores[$0]) > weights[$1] * evidence(scores[$1]) }
            .prefix(3).map { topics[$0] }.joined(separator: " · ")
    }
}
