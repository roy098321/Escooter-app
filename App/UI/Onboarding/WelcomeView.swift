import CorckieCore
import SwiftUI
import UIKit

/// A-06 (owner 18 Nov, D-PR-10): one welcome screen before step 1 "Connect your scooter", first launch only. Top two thirds = the
/// theme image with a slow zoom-out (~6 s; none with Reduce Motion), its bottom edge fading to dark. Bottom third: one line of value,
/// "See what it does" (the optional 7-card tour) and the small "Get started" straight into C27's 3 steps. Copy in `NewRider`.
struct WelcomeView: View {
    /// Settings → About → App tour opens the tour alone
    var tourOnly = false
    var onDone: () -> Void
    @State private var card: Int?
    @State private var zoomedOut = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let page = Color(white: 0.08)

    var body: some View {
        ZStack {
            Self.page.ignoresSafeArea()
            if let card { tour(card) } else if !tourOnly { welcome }
        }
        .environment(\.colorScheme, .dark)
        .onAppear { if tourOnly { card = 0 } }
    }

    // MARK: Welcome

    private var welcome: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                hero
                    .frame(width: geo.size.width, height: (geo.size.height + geo.safeAreaInsets.top) * 2 / 3)
                    .clipped()
                    .overlay(alignment: .bottom) {
                        LinearGradient(colors: [Self.page.opacity(0), Self.page], startPoint: .top, endPoint: .bottom)
                            .frame(height: 140)
                            .accessibilityHidden(true)
                    }
                VStack(spacing: 8) {
                    Text(NewRider.welcomeTitle)
                        .font(.title2.weight(.heavy))
                        .multilineTextAlignment(.center)
                    Text(NewRider.welcomeLine)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 12)
                    Button {
                        withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .spring(duration: 0.35)) { card = 0 }
                    } label: {
                        Text(NewRider.welcomeTourButton).font(.headline).frame(maxWidth: .infinity).padding(.vertical, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .buttonBorderShape(.capsule)
                    Button(NewRider.welcomeStartButton, action: onDone)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                        .frame(minHeight: DS.hit)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
            .ignoresSafeArea(edges: .top)
        }
        .onAppear {
            guard !reduceMotion else { zoomedOut = true; return }
            withAnimation(.timingCurve(0.2, 0.7, 0.2, 1, duration: 6)) { zoomedOut = true }
        }
    }

    /// The owner's theme image when it is in the app's assets ("WelcomeHero"), else a plain orange glow with the app mark
    @ViewBuilder private var hero: some View {
        Group {
            if let image = UIImage(named: "WelcomeHero") {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .accessibilityLabel("Two riders on e-scooters along a beachfront at sunset, under the CorckieApp logo")
            } else {
                ZStack {
                    RadialGradient(colors: [Theme.accent.opacity(0.85), Self.page], center: .center, startRadius: 10, endRadius: 320)
                    VStack(spacing: 10) {
                        Image("AppMark").resizable().frame(width: 96, height: 96).clipShape(Circle())
                        Text("CorckieApp").font(.largeTitle.weight(.bold)).fontDesign(.rounded)
                        Text("ride smarter").font(.title3).foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("CorckieApp, ride smarter")
            }
        }
        .scaleEffect(zoomedOut ? 1 : 1.12, anchor: .top)
    }

    // MARK: Tour

    private func tour(_ index: Int) -> some View {
        let cards = NewRider.tour
        return VStack(spacing: 0) {
            HStack {
                Spacer()
                Button("Skip", action: onDone)
                    .foregroundStyle(.secondary)
                    .frame(minHeight: DS.hit)
            }
            TabView(selection: Binding(get: { index }, set: { card = $0 })) {
                ForEach(cards.indices, id: \.self) { i in
                    VStack(spacing: 0) {
                        Spacer()
                        Image(systemName: cards[i].symbol)
                            .scaledFont(64, weight: .light, relativeTo: .largeTitle, design: .default)
                            .foregroundStyle(Theme.accent)
                            .accessibilityHidden(true)
                        Text(cards[i].title)
                            .font(.title.weight(.heavy))
                            .multilineTextAlignment(.center)
                            .padding(.top, 32)
                        Text(cards[i].line)
                            .font(.title3)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 300)
                            .padding(.top, 10)
                        Spacer()
                    }
                    .accessibilityElement(children: .combine)
                    .tag(i)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            HStack(spacing: 7) {
                ForEach(cards.indices, id: \.self) { i in
                    Capsule()
                        .fill(i == index ? Theme.accent : Color(white: 0.29))
                        .frame(width: i == index ? 20 : 7, height: 7)
                }
            }
            .animation(reduceMotion ? nil : .spring(duration: 0.3), value: index)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Card \(index + 1) of \(cards.count)")
            .padding(.bottom, 22)
            Button {
                if index >= cards.count - 1 { onDone() } else { withAnimation { card = index + 1 } }
            } label: {
                Text(NewRider.tourButton(card: index)).font(.headline).frame(maxWidth: .infinity).padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .buttonBorderShape(.capsule)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 24)
    }
}
