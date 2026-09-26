import SwiftUI

/// 1–5 stars; clicking the current rating again clears it (READ-02).
struct RatingControl: View {
    let rating: Int
    let onChange: (Int) -> Void

    var body: some View {
        HStack(spacing: 3) {
            ForEach(1...5, id: \.self) { value in
                Button {
                    onChange(value == rating ? 0 : value)
                } label: {
                    Image(systemName: value <= rating ? "star.fill" : "star")
                        .foregroundStyle(value <= rating ? Color.orange : Color.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(value) 星")
            }
            Text(rating == 0 ? "未评分" : "\(rating) 星")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.leading, 4)
        }
    }
}
