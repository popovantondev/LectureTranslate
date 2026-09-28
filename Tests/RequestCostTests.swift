import Foundation

@main
enum RequestCostTests {
    static func main() {
        var passed = 0
        func check(_ condition: Bool, _ name: String) {
            guard condition else { fputs("FAIL: \(name)\n", stderr); exit(1) }
            passed += 1
        }
        let now = Date()
        func window(_ remaining: Double?, duration: Int, reset: Date?) -> LimitWindow {
            LimitWindow(usedPercent: remaining.map { 100 - $0 }, windowDurationMins: duration, resetsAt: reset?.timeIntervalSince1970)
        }
        func quota(short: Double?, week: Double?, checkedAt: Date = now, reached: String? = nil) -> QuotaSnapshot {
            QuotaSnapshot(checkedAt: checkedAt, bucket: LimitBucket(primary: window(short, duration: 300, reset: now.addingTimeInterval(3600)),
                secondary: window(week, duration: 10080, reset: now.addingTimeInterval(86_400)), rateLimitReachedType: reached, planType: "plus"))
        }
        check(ReserveContinuation.serviceHasPositiveQuota(quota(short: 80, week: 90)), "positive fresh service quota supports reserve continuation prompt")
        check(!ReserveContinuation.serviceHasPositiveQuota(quota(short: 0, week: 90)), "zero service quota blocks reserve continuation")
        check(!ReserveContinuation.serviceHasPositiveQuota(quota(short: nil, week: 90)), "unknown window blocks reserve continuation")
        check(!ReserveContinuation.serviceHasPositiveQuota(quota(short: 80, week: 90, checkedAt: now.addingTimeInterval(-121))), "stale quota blocks reserve continuation")
        check(!ReserveContinuation.serviceHasPositiveQuota(quota(short: 80, week: 90, reached: "weekly")), "service refusal blocks reserve continuation")
        check(quota(short: 16, week: 40).decision(reserve: 15, now: now) == .allowed, "headroom above reserve remains admissible regardless of forecast cost")
        check(quota(short: 15, week: 40).decision(reserve: 15, now: now) != .allowed, "actual reserve threshold blocks absent current-run confirmation")

        check(ParallelStopPriority.shouldReplace(nil, with: .quota), "first quota refusal sets a global stop")
        check(ParallelStopPriority.shouldReplace(.quota, with: .quotaSafetyStop), "safety pause outranks ordinary quota pause")
        check(ParallelStopPriority.shouldReplace(.quotaUnavailable("unknown"), with: .quotaSafetyStop), "safety pause has highest priority")
        check(!ParallelStopPriority.shouldReplace(.quotaSafetyStop, with: .quota), "ordinary quota cannot weaken safety pause")
        check(ParallelStopPriority.shouldReplace(.quota, with: .quotaUnavailable("unknown")), "unknown service state upgrades timed quota wait")
        check(!ParallelStopPriority.shouldReplace(nil, with: .failed("one bad source")), "one bad lecture never stops independent lectures globally")
        print("PASS: \(passed) reserve admission checks. Synthetic quota only; no service, model or GUI calls.")
    }
}
