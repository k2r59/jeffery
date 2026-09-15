import Foundation
import MediaPlayer
import UIKit
import Combine

/// Lecteur système (Apple Music / bibliothèque) : état « en cours » et commandes de base.
@MainActor
final class MusicController: ObservableObject {
    @Published private(set) var title: String?
    @Published private(set) var artist: String?
    @Published private(set) var artwork: UIImage?
    @Published private(set) var isPlaying = false
    @Published private(set) var authorized = false

    private let player = MPMusicPlayerController.systemMusicPlayer
    private var observers: [NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .MPMusicPlayerControllerNowPlayingItemDidChange, object: player, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        })
        observers.append(center.addObserver(forName: .MPMusicPlayerControllerPlaybackStateDidChange, object: player, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        })
        player.beginGeneratingPlaybackNotifications()
        refresh()
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    func requestAuthorization() {
        MPMediaLibrary.requestAuthorization { [weak self] status in
            Task { @MainActor in
                self?.authorized = status == .authorized
                self?.refresh()
            }
        }
    }

    func refresh() {
        isPlaying = player.playbackState == .playing
        let item = player.nowPlayingItem
        title = item?.title
        artist = item?.artist ?? item?.albumArtist
        artwork = item?.artwork?.image(at: CGSize(width: 120, height: 120))
    }

    func togglePlayPause() { isPlaying ? player.pause() : player.play() }
    func next() { player.skipToNextItem() }
    func previous() { player.skipToPreviousItem() }
}
