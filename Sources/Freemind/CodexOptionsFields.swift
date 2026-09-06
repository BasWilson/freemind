import SwiftUI
import FreemindCore

struct CodexOptionsFields: View {
    @Binding var options: CodexOptions
    var body: some View {
        Group {
            Section("Model & profile") {
                TextField("Model", text: $options.model, prompt: Text("Use Codex default"))
                TextField("Profile", text: $options.profile, prompt: Text("Use Codex default"))
                Picker("Reasoning effort", selection: $options.reasoning) {
                    Text("Use Codex default").tag("")
                    ForEach(["minimal", "low", "medium", "high", "xhigh", "max", "ultra"], id: \.self) { Text($0).tag($0) }
                }
                Text("Model and profile names are passed to your installed CLI. Available effort levels depend on the model.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Permissions") {
                Toggle("Trust workspace when opening Codex", isOn: $options.automaticallyTrustWorkspace)
                Text("Loads this project’s Codex configuration, hooks, and rules without the directory trust prompt.").font(.caption).foregroundStyle(.secondary)
                Picker("Sandbox", selection: $options.sandbox) {
                    Text("Use Codex default").tag(""); Text("Read only").tag("read-only"); Text("Workspace write").tag("workspace-write"); Text("Full access").tag("danger-full-access")
                }
                Picker("Approval policy", selection: $options.approval) {
                    Text("Use Codex default").tag(""); Text("On request").tag("on-request"); Text("Automatic review").tag("auto"); Text("Never ask").tag("never")
                }
                TextField("Additional directories (one per line)", text: lines($options.additionalDirectories), axis: .vertical).lineLimit(2...4)
            }
            Section("Features") {
                Toggle("Enable web search", isOn: $options.webSearch)
                Toggle("Keep terminal scrollback (inline display)", isOn: $options.inline)
                Toggle("Show Codex activity in Freemind", isOn: $options.hooks)
                Text("Local hooks record session IDs and activity states. They do not change prompts or approve actions.").font(.caption).foregroundStyle(.secondary)
                Picker("Local model provider", selection: $options.localProvider) {
                    Text("Use configured provider").tag(""); Text("Ollama").tag("ollama"); Text("LM Studio").tag("lmstudio")
                }
            }
            Section("Advanced") {
                TextField("Codex executable", text: $options.executable, prompt: Text("Find codex in your login shell’s PATH"))
                TextField("Config overrides (key=value, one per line)", text: lines($options.configOverrides), axis: .vertical).lineLimit(2...5)
                TextField("Additional CLI arguments", text: $options.extraArguments, prompt: Text("--enable feature_name"), axis: .vertical).lineLimit(2...4)
                Text("Arguments support quoted values. Shell substitutions are passed literally. New CLI options can be used here without an app update.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private func lines(_ binding: Binding<[String]>) -> Binding<String> {
        Binding(get: { binding.wrappedValue.joined(separator: "\n") }, set: { binding.wrappedValue = $0.components(separatedBy: .newlines) })
    }
}
