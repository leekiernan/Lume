/// Presentation only: the caller's pagination/import machine still owns work.
/// Existing rows remain usable while another page or a refresh is in flight.
enum CollectionGridPresentation: Equatable {
    case content
    case loading
    case empty

    static func resolve(hasItems: Bool, isLoading: Bool) -> Self {
        if hasItems { return .content }
        return isLoading ? .loading : .empty
    }
}
