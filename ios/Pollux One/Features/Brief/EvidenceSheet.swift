import SwiftUI

/// 展开后每源一行：发布方 · 引文或说明 · 时间。
/// 行数等于独立源数，**不等于**总篇数——被归并的转载只在末行以数字出现。
struct EvidenceSheet: View {
    let claim: ClaimEvidence

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(claim.sources) { source in
                HStack(alignment: .firstTextBaseline, spacing: 9) {
                    Text(source.publisher)
                        .font(.system(size: 12))
                        .frame(minWidth: 62, alignment: .leading)
                    Text(source.note)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(source.time)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
            if let footer = EvidenceFooter(mergedAwayCount: claim.mergedAwayCount).text {
                Text(footer)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.top, 3)
    }
}
