import CorckieCore
import SwiftUI

/// A-24 (audit 18 Nov, batch 9): the credits the map, weather and holiday licences require, visible to every rider (they were only
/// inside Developer). Settings → About → Credits.
struct CreditsView: View {
    var body: some View {
        List {
            Section {
                ForEach(NewRider.credits, id: \.what) { c in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(c.what).font(.subheadline.weight(.semibold))
                        Text(c.who).font(.footnote).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .glassRows()
        }
        .glassList()
        .navigationTitle("Credits")
        .screen("Credits")
    }
}
