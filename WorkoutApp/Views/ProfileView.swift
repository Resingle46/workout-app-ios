import SwiftUI

struct ProfileView: View {
    @Environment(AppStore.self) private var store

    var body: some View {
        Form {
            Section(NSLocalizedString("profile.personal", comment: "")) {
                TextField(NSLocalizedString("profile.sex", comment: ""), text: Binding(
                    get: { store.profile.sex },
                    set: { store.profile.sex = $0; store.save() }
                ))
                Stepper(value: Binding(
                    get: { store.profile.age },
                    set: { store.profile.age = $0; store.save() }
                ), in: 10...100) {
                    Text(String(format: NSLocalizedString("profile.age_value", comment: ""), store.profile.age))
                }
                HStack {
                    Text(NSLocalizedString("profile.weight", comment: ""))
                    Spacer()
                    TextField("0", value: Binding(
                        get: { store.profile.weight },
                        set: { store.profile.weight = $0; store.save() }
                    ), format: .number)
                    .multilineTextAlignment(.trailing)
                    .keyboardType(.decimalPad)
                    .frame(width: 90)
                }
                HStack {
                    Text(NSLocalizedString("profile.height", comment: ""))
                    Spacer()
                    TextField("0", value: Binding(
                        get: { store.profile.height },
                        set: { store.profile.height = $0; store.save() }
                    ), format: .number)
                    .multilineTextAlignment(.trailing)
                    .keyboardType(.decimalPad)
                    .frame(width: 90)
                }
            }
        }
        .navigationTitle("tab.profile")
    }
}
