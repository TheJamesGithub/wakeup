import Foundation

/// Reads when the sideloaded app's signature runs out (7 days on a free Apple ID).
enum ProvisionInfo {
    static let expiryDate: Date? = {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .isoLatin1),
              let start = text.range(of: "<?xml"),
              let end = text.range(of: "</plist>") else { return nil }
        let xml = String(text[start.lowerBound..<end.upperBound])
        guard let xmlData = xml.data(using: .isoLatin1),
              let plist = try? PropertyListSerialization.propertyList(from: xmlData, options: [], format: nil),
              let dict = plist as? [String: Any] else { return nil }
        return dict["ExpirationDate"] as? Date
    }()

    static var daysLeft: Double? {
        guard let exp = expiryDate else { return nil }
        return exp.timeIntervalSinceNow / 86400
    }
}
