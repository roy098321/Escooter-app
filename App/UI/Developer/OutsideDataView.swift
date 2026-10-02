import SwiftUI

/// Developer → Outside data: the probes arrive in F09.
struct OutsideDataView: View {
    var body: some View {
        ContentUnavailableView("Outside data", systemImage: "cloud.sun",
                               description: Text("The source probes arrive with the next build step (F09)."))
            .navigationTitle("Outside data")
    }
}
