import SwiftUI

struct ParamSlider<Root>: View {
    let spec: ParamSpec<Root>
    let defaults: Root
    @Binding var root: Root

    private var value: Binding<Double> {
        Binding(
            get: { Double(root[keyPath: spec.key]) },
            set: { v in
                let snapped = (v / Double(spec.step)).rounded() * Double(spec.step)
                root[keyPath: spec.key] = Float(min(Double(spec.max), max(Double(spec.min), snapped)))
            }
        )
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(spec.title)
                .frame(width: 190, alignment: .leading)
                .lineLimit(1)
            Slider(value: value, in: Double(spec.min)...Double(spec.max))
            Text(String(format: "%.\(spec.decimals)f", root[keyPath: spec.key]))
                .monospacedDigit()
                .frame(width: 70, alignment: .trailing)
                .foregroundStyle(.secondary)
            Button {
                root[keyPath: spec.key] = defaults[keyPath: spec.key]
            } label: {
                Image(systemName: "arrow.counterclockwise")
            }
            .buttonStyle(.borderless)
            .help("Reset to default")
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model = SceneModel.shared

    var body: some View {
        Form {
            Section("General") {
                Toggle("Launch at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                Picker("Frame rate", selection: $model.fpsLimit) {
                    Text("Display maximum").tag(0)
                    Text("120 fps").tag(120)
                    Text("60 fps").tag(60)
                    Text("30 fps").tag(30)
                }
                Toggle("Pause wallpaper", isOn: $model.paused)
                Text("Rendering also pauses automatically while the screen is locked, asleep, or covered.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                ForEach(ParamCatalog.basicWave) { ParamSlider(spec: $0, defaults: WaveParams(), root: $model.wave) }
                DisclosureGroup("Advanced wave shaping") {
                    ForEach(ParamCatalog.advancedWave) { ParamSlider(spec: $0, defaults: WaveParams(), root: $model.wave) }
                }
                DisclosureGroup("Reverse-engineered spline pipeline") {
                    ForEach(ParamCatalog.reversePipeline) { ParamSlider(spec: $0, defaults: WaveParams(), root: $model.wave) }
                }
                DisclosureGroup("Custom · RGB background") {
                    ForEach(ParamCatalog.customColor) { ParamSlider(spec: $0, defaults: WaveParams(), root: $model.wave) }
                }
                Button("Reset all wave settings") { model.resetWave() }
            } header: {
                Text("Wave")
            }

            Section {
                ForEach(ParamCatalog.particles) { ParamSlider(spec: $0, defaults: ParticleParams(), root: $model.particles) }
                Button("Reset sparkles") { model.resetParticles() }
            } header: {
                Text("Sparkles")
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 560, minHeight: 480)
    }
}
