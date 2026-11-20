// SpinBox.swift
// Small numeric field with stepper arrows, like the Windows editor's spin boxes.

import SwiftUI

struct SpinBox: View {
    @Binding var value: Int
    var range: ClosedRange<Int>
    var width: CGFloat = 46
    var alignment: TextAlignment = .trailing

    var body: some View {
        HStack(spacing: 2) {
            TextField("", value: $value, format: .number)
                .textFieldStyle(.squareBorder)
                .multilineTextAlignment(alignment)
                .frame(width: width)
            Stepper("", value: $value, in: range)
                .labelsHidden()
                .controlSize(.mini)
        }
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
