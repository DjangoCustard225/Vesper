import AetherEngine
import SwiftUI
import UIKit

struct AetherVideoSurface: View {
    let controller: AetherPlaybackController

    var body: some View {
        ZStack {
            AetherRenderSurface(controller: controller)
            GeometryReader { geometry in
                let cues = controller.subtitleCues.filter {
                    $0.startTime <= controller.subtitleTime && controller.subtitleTime < $0.endTime
                }
                let text = cues.compactMap(\.text).joined(separator: "\n")
                ForEach(cues) { cue in
                    if case .image(let subtitle) = cue.body {
                        let rect = subtitleRect(subtitle, size: geometry.size)
                        Image(decorative: subtitle.cgImage, scale: 1).resizable()
                            .frame(width: rect.width, height: rect.height).position(
                                x: rect.midX, y: rect.midY)
                    }
                }
                if !text.isEmpty {
                    VStack {
                        Spacer()
                        Text(text).font(.system(size: 22, weight: .medium)).multilineTextAlignment(.center)
                            .foregroundStyle(.white).padding(.horizontal, 8).padding(.vertical, 4)
                            .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                            .padding(.horizontal, 42).padding(.bottom, 28)
                    }.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }.allowsHitTesting(false)
        }
    }

    private func subtitleRect(_ subtitle: SubtitleImage, size: CGSize) -> CGRect {
        let ratio = controller.videoAspect > 0 ? controller.videoAspect : 16 / 9
        let scale =
            controller.fillsScreen
            ? max(size.width / ratio, size.height) : min(size.width / ratio, size.height)
        let video = CGSize(width: scale * ratio, height: scale)
        let canvasHeight =
            subtitle.canvasSize.width > 0
            ? video.width * subtitle.canvasSize.height / subtitle.canvasSize.width : video.height
        return CGRect(
            x: (size.width - video.width) / 2 + subtitle.position.minX * video.width,
            y: (size.height - canvasHeight) / 2 + subtitle.position.minY * canvasHeight,
            width: subtitle.position.width * video.width, height: subtitle.position.height * canvasHeight)
    }
}

private struct AetherRenderSurface: UIViewRepresentable {
    let controller: AetherPlaybackController

    func makeUIView(context: Context) -> AetherPlayerView {
        let view = AetherPlayerView(frame: .zero)
        controller.attach(to: view)
        return view
    }

    func updateUIView(_ uiView: AetherPlayerView, context: Context) {}
}
