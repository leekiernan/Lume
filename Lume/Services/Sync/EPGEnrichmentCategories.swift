import Foundation

/// Category-wide selection only narrows the independently verified station registry.
/// It never infers broadcast identity from a provider's category name.
nonisolated enum EPGEnrichmentCategories {
    static func defaultEnabled(name: String) -> Bool {
        let normalized = name.lowercased().filter { $0.isLetter || $0.isNumber }
        return normalized == "ukentertainment" || normalized == "ukskysports"
    }

    static func isSelected(name: String, override: Bool?) -> Bool {
        override ?? defaultEnabled(name: name)
    }

    static func isEligible(name: String, type: String, hidden: Bool, override: Bool?) -> Bool {
        type == "live" && !hidden && isSelected(name: name, override: override)
    }
}
