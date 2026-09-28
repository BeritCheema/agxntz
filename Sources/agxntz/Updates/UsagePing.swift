import Foundation

/// Anonymous usage count: POSTs `{"id": <install ID>, "version": <app version>}`
/// to agxntz.com at most once per 24 hours — the last send time is persisted, so
/// relaunching doesn't send again. The ID is DeviceID: a salted one-way hash of
/// the hardware UUID, stable per Mac and not reversible. Nothing else is ever
/// sent. Fire-and-forget: failures are ignored and never affect the app. Update
/// checks are independent of this (Sparkle reads the feed from GitHub, also daily).
@MainActor
enum UsagePing {
    /// AGXNTZ_PING_URL overrides the endpoint for testing.
    static let endpoint = URL(string: ProcessInfo.processInfo.environment["AGXNTZ_PING_URL"]
                                      ?? "https://agxntz.com/update")!
    private static let interval: TimeInterval = 24 * 60 * 60
    private static let lastSentKey = "usagePingLastSent"
    private static var timer: Timer?

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral   // no cookies/cache
        config.timeoutIntervalForRequest = 15
        return URLSession(configuration: config)
    }()

    /// Send if a day has passed since the last send, then re-check hourly (the
    /// hourly check is local only — a request goes out once per day at most).
    /// No-op for dev builds unless forced for testing.
    static func start() {
        guard UpdateManager.shouldRun else { return }
        sendIfDue()
        timer?.invalidate()
        let t = Timer(timeInterval: 60 * 60, repeats: true) { _ in
            MainActor.assumeIsolated { sendIfDue() }
        }
        t.tolerance = 10 * 60
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    static func sendIfDue() {
        let settings = AppSettings.shared
        let defaults = UserDefaults.standard
        if let last = defaults.object(forKey: lastSentKey) as? Date,
           Date().timeIntervalSince(last) < interval { return }
        // Record the attempt up front so a failing server isn't retried hourly.
        defaults.set(Date(), forKey: lastSentKey)

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body = ["id": settings.installID, "version": UpdateManager.currentVersion]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        Log.d("ping: \(body)")
        session.dataTask(with: request) { _, response, error in
            let status = (response as? HTTPURLResponse)?.statusCode
            Log.d("ping: done status=\(status.map(String.init) ?? "-") error=\(error?.localizedDescription ?? "-")")
        }.resume()
    }
}
