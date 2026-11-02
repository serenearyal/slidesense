import CoreGraphics

/// The three usable edges of the trackpad, in normalised coordinates where
/// `x` goes left → right and `y` goes bottom → top (see `TrackpadMonitor`).
public enum Edge: String, Codable, CaseIterable, Sendable {
    case left
    case right
    case bottom

    public var label: String {
        switch self {
        case .left: return "Left edge"
        case .right: return "Right edge"
        case .bottom: return "Bottom edge"
        }
    }
}

/// Pure geometry helpers. All input points are normalised to 0…1.
public struct EdgeGeometry: Sendable {
    /// Width of the edge band as a fraction of the trackpad dimension.
    public var edgeWidth: Double
    /// Restrict the left/right edges to the lower quarter of the trackpad.
    public var bottomQuarterOnly: Bool
    /// Size of the top-right corner used for Quick Mute.
    public var cornerSize: Double

    public init(edgeWidth: Double = 0.18, bottomQuarterOnly: Bool = false, cornerSize: Double = 0.16) {
        self.edgeWidth = min(max(edgeWidth, 0.05), 0.45)
        self.bottomQuarterOnly = bottomQuarterOnly
        self.cornerSize = cornerSize
    }

    public init(settings: Settings) {
        self.init(edgeWidth: settings.edgeWidth, bottomQuarterOnly: settings.bottomQuarterOnly)
    }

    /// Which edge, if any, the point is close enough to.
    ///
    /// When a point sits in a corner the closest edge wins, so the bottom
    /// strip never steals touches that are clearly on the left or right band.
    public func edge(at point: CGPoint) -> Edge? {
        let x = Double(point.x)
        let y = Double(point.y)
        guard (0...1).contains(x), (0...1).contains(y) else { return nil }

        var candidates: [(edge: Edge, distance: Double)] = []
        if x <= edgeWidth { candidates.append((.left, x)) }
        if x >= 1 - edgeWidth { candidates.append((.right, 1 - x)) }
        if y <= edgeWidth { candidates.append((.bottom, y)) }

        guard let best = candidates.min(by: { $0.distance < $1.distance }) else { return nil }

        if bottomQuarterOnly, best.edge != .bottom, y > 0.25 {
            return nil
        }
        return best.edge
    }

    /// Whether a point is still inside one edge's band, plus `margin`. Unlike
    /// `edge(at:)` this ignores the other bands, so a finger near a corner does not
    /// "leave" its edge just because another edge is closer.
    public func band(_ edge: Edge, contains point: CGPoint, margin: Double = 0) -> Bool {
        let x = Double(point.x)
        let y = Double(point.y)
        switch edge {
        case .left: return x <= edgeWidth + margin
        case .right: return x >= 1 - edgeWidth - margin
        case .bottom: return y <= edgeWidth + margin
        }
    }

    /// The top-right corner region used for Quick Mute.
    public func isQuickMuteCorner(_ point: CGPoint) -> Bool {
        let x = Double(point.x)
        let y = Double(point.y)
        return x >= 1 - cornerSize && y >= 1 - cornerSize
    }

    /// The span of trackpad travel that maps onto a full 0…1 change.
    public func travelSpan(for edge: Edge) -> Double {
        switch edge {
        case .bottom:
            return 0.75 * max(edgeWidth, 0.08)
        case .left, .right:
            let usable = bottomQuarterOnly ? 0.25 : 1.0
            return 0.75 * usable
        }
    }
}
