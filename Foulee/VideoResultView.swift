import SwiftUI
import AVKit
import Photos

struct VideoItem: Identifiable {
    let url: URL
    var id: URL { url }
}

/// Aperçu de la vidéo créée, avec enregistrement dans Photos et partage.
struct VideoResultView: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer
    @State private var saved = false
    @State private var saveError = false

    init(url: URL) {
        self.url = url
        _player = State(initialValue: AVPlayer(url: url))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                VideoPlayer(player: player)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .onAppear { player.play() }
                    .onDisappear { player.pause() }

                HStack(spacing: 12) {
                    Button {
                        saveToPhotos()
                    } label: {
                        Label(saved ? "Enregistrée" : "Dans Photos",
                              systemImage: saved ? "checkmark" : "square.and.arrow.down")
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 50)
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .disabled(saved)

                    ShareLink(item: url) {
                        Label("Partager", systemImage: "square.and.arrow.up")
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 50)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                }
            }
            .padding()
            .navigationTitle("Ta vidéo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") { dismiss() }
                }
            }
            .alert("Accès à Photos refusé", isPresented: $saveError) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Autorise Valentin Entraîneur à ajouter des photos dans Réglages, ou utilise Partager.")
            }
        }
    }

    private func saveToPhotos() {
        let fileURL = url
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async { saveError = true }
                return
            }
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: fileURL)
            }) { ok, _ in
                DispatchQueue.main.async {
                    if ok { saved = true } else { saveError = true }
                }
            }
        }
    }
}
