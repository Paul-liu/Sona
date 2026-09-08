//
//  Playlist.swift
//  Sona
//
//  歌单数据模型
//

import Foundation

/// 歌单
struct Playlist: Identifiable, Hashable {
    let id: String
    var name: String
    var source: TrackSource
    var tracks: [Track]
    var createdAt: Date

    init(
        id: String,
        name: String,
        source: TrackSource,
        tracks: [Track] = [],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.source = source
        self.tracks = tracks
        self.createdAt = createdAt
    }

    static func == (lhs: Playlist, rhs: Playlist) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
