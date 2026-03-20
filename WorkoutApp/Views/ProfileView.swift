import SwiftUI

struct ProfileView: View {
    @Environment(AppStore.self) private var store
    @State private var activePicker: ProfilePickerField?

    var body: some View {
        @Bindable var store = store

        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("tab.profile")
                    .font(.system(size: 38, weight: .black, design: .rounded))

                AppCard {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("profile.card_title")
                            .font(.system(size: 28, weight: .black, design: .rounded))
                        Text("profile.card_description")
                            .foregroundStyle(AppTheme.secondaryText)
                    }
                }

                AppCard {
                    VStack(alignment: .leading, spacing: 16) {
                        AppSectionTitle(titleKey: "profile.personal")

                        profileRow(titleKey: "profile.sex", value: store.profile.sex) {
                            activePicker = .sex
                        }

                        profileRow(titleKey: "profile.age", value: "\(store.profile.age)") {
                            activePicker = .age
                        }

                        profileRow(titleKey: "profile.weight", value: "\(store.profile.weight.appNumberText) kg") {
                            activePicker = .weight
                        }

                        profileRow(titleKey: "profile.height", value: "\(Int(store.profile.height)) cm") {
                            activePicker = .height
                        }
                    }
                }

                AppCard {
                    VStack(alignment: .leading, spacing: 16) {
                        AppSectionTitle(titleKey: "profile.language")

                        Picker("", selection: Binding(
                            get: { store.selectedLanguageCode },
                            set: { store.updateLanguage($0) }
                        )) {
                            Text("English").tag("en")
                            Text("Русский").tag("ru")
                        }
                        .pickerStyle(.segmented)
                    }
                }
            }
            .padding(20)
        }
        .sheet(item: $activePicker) { picker in
            ProfilePickerSheet(
                picker: picker,
                profile: store.profile,
                onSave: { updatedProfile in
                    store.updateProfile { profile in
                        profile = updatedProfile
                    }
                }
            )
            .presentationDetents([.height(360)])
            .presentationDragIndicator(.hidden)
            .presentationBackground(.clear)
        }
        .navigationBarTitleDisplayMode(.inline)
        .appScreenBackground()
    }

    private func profileRow(titleKey: LocalizedStringKey, value: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Text(titleKey)
                    .foregroundStyle(AppTheme.primaryText)
                Spacer()
                Text(value)
                    .foregroundStyle(AppTheme.secondaryText)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(AppTheme.secondaryText)
            }
            .padding(.vertical, 10)
        }
        .buttonStyle(.plain)
    }
}

enum ProfilePickerField: String, Identifiable {
    case sex
    case age
    case weight
    case height

    var id: String { rawValue }
}

private struct ProfilePickerSheet: View {
    @Environment(\.dismiss) private var dismiss

    let picker: ProfilePickerField
    let profile: UserProfile
    let onSave: (UserProfile) -> Void

    @State private var sex: String
    @State private var age: Int
    @State private var weightStep: Int
    @State private var height: Int

    init(picker: ProfilePickerField, profile: UserProfile, onSave: @escaping (UserProfile) -> Void) {
        self.picker = picker
        self.profile = profile
        self.onSave = onSave
        _sex = State(initialValue: profile.sex == "F" ? "F" : "M")
        _age = State(initialValue: min(max(profile.age, 10), 100))
        _weightStep = State(initialValue: min(max(Int((profile.weight * 2).rounded()), 60), 500))
        _height = State(initialValue: min(max(Int(profile.height.rounded()), 120), 230))
    }

    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Color.white.opacity(0.28))
                .frame(width: 44, height: 5)
                .padding(.top, 10)
                .padding(.bottom, 18)

            HStack {
                Text(title(for: picker))
                    .font(.title3.weight(.heavy))
                    .foregroundStyle(AppTheme.primaryText)
                Spacer()
                Button("action.done") {
                    onSave(
                        UserProfile(
                            sex: sex,
                            age: age,
                            weight: Double(weightStep) / 2,
                            height: Double(height),
                            appLanguageCode: profile.appLanguageCode
                        )
                    )
                    dismiss()
                }
                .foregroundStyle(AppTheme.primaryText)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 8)

            pickerContent
                .frame(maxWidth: .infinity)
                .frame(height: 220)
                .clipped()
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(AppTheme.surface.ignoresSafeArea())
    }

    @ViewBuilder
    private var pickerContent: some View {
        switch picker {
        case .sex:
            Picker("", selection: $sex) {
                Text("M").tag("M")
                Text("F").tag("F")
            }
            .pickerStyle(.wheel)

        case .age:
            Picker("", selection: $age) {
                ForEach(10...100, id: \.self) { value in
                    Text("\(value)")
                        .tag(value)
                }
            }
            .pickerStyle(.wheel)

        case .weight:
            Picker("", selection: $weightStep) {
                ForEach(60...500, id: \.self) { value in
                    Text("\(Double(value) / 2, specifier: "%.1f")")
                        .tag(value)
                }
            }
            .pickerStyle(.wheel)

        case .height:
            Picker("", selection: $height) {
                ForEach(120...230, id: \.self) { value in
                    Text("\(value)")
                        .tag(value)
                }
            }
            .pickerStyle(.wheel)
        }
    }

    private func title(for picker: ProfilePickerField) -> LocalizedStringKey {
        switch picker {
        case .sex:
            return "profile.sex"
        case .age:
            return "profile.age"
        case .weight:
            return "profile.weight"
        case .height:
            return "profile.height"
        }
    }
}
