//
//  VideoExportSettings.swift
//  VerticalConverter
//

import CoreMedia

struct VideoExportSettings {
    var bitrate: Int = 10          // Mbps
    var encodingMode: EncodingMode = .vbr
    var resolution: Resolution     = .fullHD
    var frameRate: FrameRate       = .fps30
    var codec: Codec = .h264

    // MARK: - Encoding Mode

    enum EncodingMode: String, CaseIterable {
        case vbr = "VBR"
        case cbr = "CBR"
        case abr = "ABR"
    }

    // MARK: - Resolution

    enum Resolution: String, CaseIterable {
        case hd     = "720p"
        case fullHD = "1080p"

        var outputSize: (width: Int, height: Int) {
            switch self {
            case .hd:     return (720,  1280)
            case .fullHD: return (1080, 1920)
            }
        }
    }

    // MARK: - Frame Rate

    enum FrameRate: String, CaseIterable {
        case fps24   = "24"
        case fps2997 = "29.97"
        case fps30   = "30"
        case fps60   = "60"

        /// セグメントに表示するラベル（29.97は DF をサブラベルで表示する用）
        var displayLabel: String {
            switch self {
            case .fps2997: return "29.97 DF"
            default:       return rawValue
            }
        }

        /// AVMutableVideoComposition.frameDuration 用
        var frameDuration: CMTime {
            switch self {
            case .fps24:   return CMTime(value: 1,    timescale: 24)
            case .fps2997: return CMTime(value: 1001, timescale: 30000)   // Drop Frame
            case .fps30:   return CMTime(value: 1,    timescale: 30)
            case .fps60:   return CMTime(value: 1,    timescale: 60)
            }
        }
    }

    // MARK: - Codec

    enum Codec: String, CaseIterable, Hashable {
        case h264 = "H.264"
        case h265 = "H.265"
        case h264VT = "H.264 (VT)"
        case h265VT = "H.265 (VT)"
        case prores422VT = "ProRes422 (VT)"
    }

    // MARK: - Container Format

    /// Output container format.
    /// `.mov` is the Apple-native container with reliable HEVC Main10 / HDR
    /// metadata support. `.mp4` offers better cross-platform compatibility
    /// but may cause playback issues with HDR HEVC in macOS QuickLook/QTX.
    /// ProRes always uses `.mov` regardless of this setting.
    enum ContainerFormat: String, CaseIterable, Hashable {
        case mov = "MOV"
        case mp4 = "MP4"
    }

    var containerFormat: ContainerFormat = .mov

    /// Resolved file extension for the current codec + container combination.
    /// ProRes always produces `.mov`. H.264 always produces `.mp4`.
    /// HEVC respects the user's `containerFormat` choice.
    var resolvedFileExtension: String {
        switch codec {
        case .prores422VT:
            return "mov"
        case .h265, .h265VT:
            return containerFormat == .mp4 ? "mp4" : "mov"
        default:
            return "mp4"
        }
    }
}
