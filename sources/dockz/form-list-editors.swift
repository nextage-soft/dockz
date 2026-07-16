import SwiftUI

/// Row-based editors for the container form. Each editor owns row state and
/// serializes back into the form's line-based text format (the format the
/// tested ContainerConfigBuilder parses). Styled for use OUTSIDE of Form
/// (plain leading-aligned fields with placeholders, no side labels).

struct KeyValueListEditor: View {
    struct Row: Identifiable {
        let id = UUID()
        var key = ""
        var value = ""
    }

    let keyPlaceholder: String
    let valuePlaceholder: String
    var addLabel = "Add variable"
    @Binding var text: String
    @State private var rows: [Row] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach($rows) { $row in
                HStack(spacing: 8) {
                    TextField("", text: $row.key, prompt: Text(keyPlaceholder))
                        .frame(width: 210)
                    Text("=").foregroundStyle(.tertiary)
                    TextField("", text: $row.value, prompt: Text(valuePlaceholder))
                    RemoveRowButton { rows.removeAll { $0.id == row.id } }
                }
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
                .multilineTextAlignment(.leading)
            }
            AddRowButton(title: addLabel) { rows.append(Row()) }
        }
        .onAppear(perform: parse)
        .onChange(of: rows.map { "\($0.key)\u{1}\($0.value)" }) { _ in serialize() }
    }

    private func parse() {
        guard rows.isEmpty else { return }
        rows = text.split(separator: "\n").compactMap { line in
            guard let equals = line.firstIndex(of: "=") else {
                return line.isEmpty ? nil : Row(key: String(line), value: "")
            }
            return Row(key: String(line[..<equals]), value: String(line[line.index(after: equals)...]))
        }
    }

    private func serialize() {
        text = rows
            .filter { !$0.key.trimmingCharacters(in: .whitespaces).isEmpty }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: "\n")
    }
}

struct PortMappingListEditor: View {
    struct Row: Identifiable {
        let id = UUID()
        var host = ""
        var container = ""
        var udp = false
    }

    @Binding var text: String
    @State private var rows: [Row] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach($rows) { $row in
                HStack(spacing: 8) {
                    TextField("", text: $row.host, prompt: Text("8080"))
                        .frame(width: 76)
                    Image(systemName: "arrow.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    TextField("", text: $row.container, prompt: Text("80"))
                        .frame(width: 76)
                    Picker("", selection: $row.udp) {
                        Text("tcp").tag(false)
                        Text("udp").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 96)
                    if !row.host.isEmpty {
                        Text("localhost:\(row.host)")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 0)
                    RemoveRowButton { rows.removeAll { $0.id == row.id } }
                }
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
                .multilineTextAlignment(.leading)
            }
            AddRowButton(title: "Add port mapping") { rows.append(Row()) }
        }
        .onAppear(perform: parse)
        .onChange(of: rows.map { "\($0.host):\($0.container):\($0.udp)" }) { _ in serialize() }
    }

    private func parse() {
        guard rows.isEmpty else { return }
        rows = text.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return nil }
            var container = parts[1]
            var udp = false
            if container.hasSuffix("/udp") { udp = true; container = String(container.dropLast(4)) }
            if container.hasSuffix("/tcp") { container = String(container.dropLast(4)) }
            return Row(host: parts[0], container: container, udp: udp)
        }
    }

    private func serialize() {
        text = rows
            .filter { !$0.host.isEmpty && !$0.container.isEmpty }
            .map { "\($0.host):\($0.container)\($0.udp ? "/udp" : "")" }
            .joined(separator: "\n")
    }
}

struct VolumeMappingListEditor: View {
    struct Row: Identifiable {
        let id = UUID()
        var source = ""
        var destination = ""
        var readOnly = false
    }

    @Binding var text: String
    @State private var rows: [Row] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach($rows) { $row in
                HStack(spacing: 8) {
                    TextField("", text: $row.source, prompt: Text("/host/path or volume"))
                    Image(systemName: "arrow.right")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    TextField("", text: $row.destination, prompt: Text("/container/path"))
                    Toggle("read-only", isOn: $row.readOnly)
                        .toggleStyle(.checkbox)
                        .font(.caption)
                    RemoveRowButton { rows.removeAll { $0.id == row.id } }
                }
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
                .multilineTextAlignment(.leading)
            }
            AddRowButton(title: "Add volume") { rows.append(Row()) }
        }
        .onAppear(perform: parse)
        .onChange(of: rows.map { "\($0.source):\($0.destination):\($0.readOnly)" }) { _ in serialize() }
    }

    private func parse() {
        guard rows.isEmpty else { return }
        rows = text.split(separator: "\n").compactMap { line in
            var parts = line.split(separator: ":").map(String.init)
            guard parts.count >= 2 else { return nil }
            var readOnly = false
            if parts.last == "ro" { readOnly = true; parts.removeLast() }
            if parts.last == "rw" { parts.removeLast() }
            guard parts.count >= 2 else { return nil }
            let destination = parts.removeLast()
            return Row(source: parts.joined(separator: ":"), destination: destination, readOnly: readOnly)
        }
    }

    private func serialize() {
        text = rows
            .filter { !$0.source.isEmpty && !$0.destination.isEmpty }
            .map { "\($0.source):\($0.destination)\($0.readOnly ? ":ro" : "")" }
            .joined(separator: "\n")
    }
}

// MARK: - Shared small controls

struct RemoveRowButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "minus.circle.fill")
                .foregroundStyle(.tertiary)
        }
        .buttonStyle(.borderless)
        .help("Remove")
    }
}

struct AddRowButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: "plus.circle")
                .font(.callout)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(Color.accentColor)
    }
}
