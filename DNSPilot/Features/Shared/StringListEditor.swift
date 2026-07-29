import SwiftUI

@MainActor
struct StringListEditor: View {
    let label: String
    let itemLabel: String
    let addLabel: String
    @Binding var values: [String]
    var normalize: ((String) -> String?)? = nil
    var itemPrompt: String? = nil

    @FocusState private var focusedIndex: Int?
    @State private var pendingFocusIndex: Int?

    var body: some View {
        LabeledContent(label) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(values.indices, id: \.self) { index in
                    HStack {
                        TextField(
                            itemLabel,
                            text: valueBinding(at: index),
                            prompt: Text(itemPrompt ?? itemLabel)
                        )
                            .frame(width: 240)
                            .focused($focusedIndex, equals: index)
                            .accessibilityLabel(itemLabel)
                            .task {
                                guard pendingFocusIndex == index else { return }
                                await Task.yield()
                                guard values.indices.contains(index) else { return }
                                pendingFocusIndex = nil
                                focusedIndex = index
                            }
                        Button(role: .destructive) {
                            values.remove(at: index)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Remove \(itemLabel)")
                        .accessibilityLabel("Remove \(itemLabel)")
                    }
                }
                Button {
                    let newIndex = values.endIndex
                    values.append("")
                    pendingFocusIndex = newIndex
                } label: {
                    Label(addLabel, systemImage: "plus")
                }
            }
        }
        .onChange(of: focusedIndex) { oldIndex, _ in
            normalizeValue(at: oldIndex)
        }
    }

    private func valueBinding(at index: Int) -> Binding<String> {
        Binding(
            get: { values.indices.contains(index) ? values[index] : "" },
            set: { value in
                guard values.indices.contains(index) else { return }
                values[index] = value
            }
        )
    }

    private func normalizeValue(at index: Int?) {
        guard let index, values.indices.contains(index), let normalize,
              let normalized = normalize(values[index]) else { return }
        values[index] = normalized
    }
}
