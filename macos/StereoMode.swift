enum StereoMode: String, CaseIterable {
    case normal, aiFullSBS, preparedSBS, fullSBS, halfSBS

    var title: String {
        switch self {
        case .normal: return "Off (Normal video)"
        case .aiFullSBS: return "2D → Full-SBS (AI, Experimental)"
        case .preparedSBS: return "2D → Full-SBS (Prepare HQ…)"
        case .fullSBS: return "Full-SBS (Already full width)"
        case .halfSBS: return "Half-SBS → Full-SBS"
        }
    }

    func aspectRatio(width: Int, height: Int) -> String? {
        guard self != .normal, self != .aiFullSBS, width > 0, height > 0, width <= Int.max / 2 else { return nil }
        return "\(self == .halfSBS ? width * 2 : width):\(height)"
    }
}
