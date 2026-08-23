import SwiftUI

struct EbookLibraryView_tvOS: View {
    var body: some View {
        NavigationStack {
            LibraryGridView_tvOS(filter: .ebooks, title: "Books")
        }
    }
}
