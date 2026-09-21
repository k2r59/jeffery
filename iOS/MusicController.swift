import Foundation
import MediaPlayer
import AVFoundation
import UIKit
import Combine

/// Lecteurs tiers que l'on peut ouvrir (iOS n'expose ni leur titre ni leurs commandes aux autres apps).
struct MusicApp: Identifiable, Equatable {
    let id: String
    let name: String
    let scheme: String
    static let all: [MusicApp] = [
        MusicApp(id: "spotify", name: "Spotify", scheme: "spotify://"),
        MusicApp(id: "deezer", name: "Deezer", scheme: "deezer://"),
        MusicApp(id: "music", name: "Musique", scheme: "music://"),
        MusicApp(id: "youtubemusic", name: "YouTube Music", scheme: "youtubemusic://"),
        MusicApp(id: "soundcloud", name: "SoundCloud", scheme: "soundcloud://"),
    ]
}

/// Lecteur système (Apple Music / bibliothèque) : état « en cours » et commandes de base.
@MainActor
final class MusicController: ObservableObject {
    @Published private(set) var title: String?
    @Published private(set) var artist: String?
    @Published private(set) var isPlaying = false
    @Published private(set) var authorized = false
    /// Une autre app joue du son (Spotify, Deezer…) : on ne connaît pas le titre mais on sait qu'elle joue.
    @Published private(set) var otherAudioPlaying = false
    @Published private(set) var installedApps: [MusicApp] = []
    @Published var lastApp: String? = UserDefaults.standard.string(forKey: "music.lastApp")
    private var pollTimer: Timer?

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
        installedApps = MusicApp.all.filter { UIApplication.shared.canOpenURL(URL(string: $0.scheme)!) }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.otherAudioPlaying = AVAudioSession.sharedInstance().isOtherAudioPlaying }
        }
    }

    /// Lecteurs à proposer : le dernier lancé en premier.
    var suggestedApps: [MusicApp] {
        installedApps.sorted { a, _ in a.id == lastApp }
    }

    func open(_ app: MusicApp) {
        lastApp = app.id
        UserDefaults.standard.set(app.id, forKey: "music.lastApp")
        if let url = URL(string: app.scheme) { UIApplication.shared.open(url) }
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        pollTimer?.invalidate()
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
    }

    func togglePlayPause() { isPlaying ? player.pause() : player.play() }
    func next() { player.skipToNextItem() }
    func previous() { player.skipToPreviousItem() }
}
