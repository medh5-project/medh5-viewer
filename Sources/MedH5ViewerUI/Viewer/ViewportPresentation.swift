import Foundation
import Observation
import SwiftUI
import MedH5Kit

/// A volume being read, shown as progress in a viewport.
struct LoadingItem: Identifiable, Equatable {
    var id: String
    var title: String
    /// 0…1, or `nil` when unknown.
    var progress: Double?
}

/// The orientation letters at the four edges of a slice view.
struct OrientationLetters: Equatable {
    var left: String
    var right: String
    var top: String
    var bottom: String
}

/// Everything a viewport's text overlay shows, published by its controller
/// after each scene build and drawn by SwiftUI over the Metal view.
@MainActor
@Observable
final class ViewportPresentation {
    var title = ""
    var titleColor: Color = .white
    var topLeft: [String] = []
    var topRight: [String] = []
    var bottomLeft: [String] = []
    var bottomRight: [String] = []
    /// How to use the view, longest first: the first that fits is shown,
    /// or none.
    var hint: [String] = []
    /// Classification labels (corner badges).
    var badges: [String] = []
    /// Layers not drawn, and why.
    var notes: [String] = []
    var orientation: OrientationLetters?
    var labels: [ViewportLabel] = []
    var loading: [LoadingItem] = []
    /// Shown instead of an image (no base image, no Metal device).
    var placeholder: String?
    var showsOrientation = true
    /// Drawn with the active-view outline.
    var isActive = false

    func update(_ p: PresentationData) {
        if isActive != p.isActive { isActive = p.isActive }
        if title != p.title { title = p.title }
        if titleColor != p.titleColor { titleColor = p.titleColor }
        if topLeft != p.topLeft { topLeft = p.topLeft }
        if topRight != p.topRight { topRight = p.topRight }
        if bottomLeft != p.bottomLeft { bottomLeft = p.bottomLeft }
        if bottomRight != p.bottomRight { bottomRight = p.bottomRight }
        if hint != p.hint { hint = p.hint }
        if badges != p.badges { badges = p.badges }
        if notes != p.notes { notes = p.notes }
        if orientation != p.orientation { orientation = p.orientation }
        if labels != p.labels { labels = p.labels }
        if loading != p.loading { loading = p.loading }
        if placeholder != p.placeholder { placeholder = p.placeholder }
        if showsOrientation != p.showsOrientation { showsOrientation = p.showsOrientation }
    }
}

/// The value form of a presentation, built off the observable.
struct PresentationData {
    var title = ""
    var titleColor: Color = .white
    var topLeft: [String] = []
    var topRight: [String] = []
    var bottomLeft: [String] = []
    var bottomRight: [String] = []
    var hint: [String] = []
    var badges: [String] = []
    var notes: [String] = []
    var orientation: OrientationLetters?
    var labels: [ViewportLabel] = []
    var loading: [LoadingItem] = []
    var placeholder: String?
    var showsOrientation = true
    var isActive = false
}
