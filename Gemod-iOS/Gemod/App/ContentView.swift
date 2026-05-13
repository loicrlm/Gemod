import SwiftUI

struct ContentView: View {
    var body: some View {
        SubscriptionView(
            viewModel: SubscriptionViewModel(
                engine: CoreEngineProvider.makeEngine()
            )
        )
    }
}

#Preview {
    ContentView()
}
