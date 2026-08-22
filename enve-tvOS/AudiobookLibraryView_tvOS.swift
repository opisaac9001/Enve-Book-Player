import SwiftUI

struct AudiobookLibraryView_tvOS: View {
    var body: some View {
        NavigationStack {
            LibraryGridView_tvOS(filter: .audiobooks, title: "Audiobooks")
        }
    }
}
