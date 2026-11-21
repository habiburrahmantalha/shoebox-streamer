@main
struct StereoModeChecks {
    static func main() {
        assert(StereoMode.normal.aspectRatio(width: 1920, height: 1080) == nil)
        assert(StereoMode.aiFullSBS.aspectRatio(width: 1920, height: 1080) == nil)
        assert(StereoMode.fullSBS.aspectRatio(width: 3840, height: 1080) == "3840:1080")
        assert(StereoMode.preparedSBS.aspectRatio(width: 3840, height: 1080) == "3840:1080")
        assert(StereoMode.halfSBS.aspectRatio(width: 1920, height: 1080) == "3840:1080")
        assert(StereoMode.halfSBS.aspectRatio(width: 1920, height: 800) == "3840:800")
        assert(StereoMode.fullSBS.aspectRatio(width: 7680, height: 2160) == "7680:2160")
        for mode in StereoMode.allCases {
            assert(mode.aspectRatio(width: 0, height: 1080) == nil)
            assert(mode.aspectRatio(width: 1920, height: 0) == nil)
            assert(mode.aspectRatio(width: Int.max, height: 1080) == nil)
            assert(StereoMode(rawValue: mode.rawValue) == mode)
        }
        print("SBS layout checks passed: full width, half width, letterboxing, reset, invalid dimensions.")
    }
}
