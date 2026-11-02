/// A server's password, made the first time it starts: four words and a
/// number, easy to type on a phone.
public enum ServerPassword {
    public static func make() -> String {
        let words = ["amber", "birch", "cedar", "delta", "ember", "fjord", "grove", "harbor", "indigo", "juniper", "kestrel",
                     "lumen", "maple", "nectar", "orbit", "pearl", "quill", "raven", "sable", "tundra", "umber", "vale",
                     "willow", "zephyr"]
        var generator = SystemRandomNumberGenerator()
        let picked = (0..<3).map { _ in words.randomElement(using: &generator) ?? "amber" }
        return picked.joined(separator: "-") + "-" + String(Int.random(in: 1000...9999, using: &generator))
    }
}
