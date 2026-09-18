import SwiftUI

/// 用户给进来的那条新闻，收成一行。⑤ 等待和 ② 审稿都靠它开头，
/// 所以它不属于任何一屏，单独放。
struct NewsTag: View {
    let news: NewsRef

    var body: some View {
        HStack(spacing: 8) {
            Text(news.publisher)
                .font(.system(size: 10.5))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 4))
            Text(news.title)
                .font(.system(size: 13))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.top, 8)
    }
}
