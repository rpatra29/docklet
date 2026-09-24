import SwiftUI
import CoreLocation

// MARK: - Models

struct WeatherDay: Identifiable {
    let id = UUID()
    let label: String
    let maxTemp: Int
    let minTemp: Int
    let code: Int
}

struct CurrentWeather {
    var tempC: Int = 0
    var code: Int = 0
    var desc: String = ""
    var city: String = ""
}

// MARK: - Monitor
// Weather:   Open-Meteo (https, no key, very reliable) — WMO weather codes.
// Location:  CoreLocation → precise lat/lon (with a 5s IP fallback if the
//            authorization prompt never resolves, common for unbundled binaries).
// Fallback:  freeipapi.com (HTTPS, no key) → lat/lon + city.

@MainActor
final class WeatherMonitor: NSObject, ObservableObject, CLLocationManagerDelegate {
    static let shared = WeatherMonitor()

    @Published var current = CurrentWeather()
    @Published var forecast: [WeatherDay] = []
    @Published var status: Status = .idle

    enum Status: Equatable {
        case idle, loading, loaded
        case error(String)
    }

    private let lm = CLLocationManager()
    private var fallbackTask: Task<Void, Never>?
    private var requestID = UUID()

    override init() {
        super.init()
        lm.delegate = self
        lm.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    func refresh(requestLocationPermission: Bool = true) {
        fallbackTask?.cancel()
        requestID = UUID()
        let id = requestID
        status = .loading
        switch lm.authorizationStatus {
        case .authorized, .authorizedAlways:
            lm.requestLocation()
            scheduleIPFallback(for: id)
        case .denied, .restricted:
            Task { await fetchViaIP(for: id) }
        case .notDetermined:
            if requestLocationPermission {
                lm.requestWhenInUseAuthorization()
                scheduleIPFallback(for: id)
            } else {
                Task { await fetchViaIP(for: id) }
            }
        @unknown default:
            Task { await fetchViaIP(for: id) }
        }
    }

    // If CoreLocation never produces a fix (e.g. the auth prompt never resolves
    // for an unbundled binary), fall back to IP geolocation after a short wait
    // so the UI never spins on "Fetching weather…" forever.
    private func scheduleIPFallback(for id: UUID) {
        fallbackTask?.cancel()
        fallbackTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            guard let self, !Task.isCancelled else { return }
            if self.status == .loading, self.requestID == id {
                await self.fetchViaIP(for: id)
            }
        }
    }

    // MARK: CLLocationManagerDelegate

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            switch self.lm.authorizationStatus {
            case .authorized, .authorizedAlways:
                self.lm.requestLocation()
            case .denied, .restricted:
                let id = self.beginFallbackRequest()
                await self.fetchViaIP(for: id)
            default:
                break
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.fallbackTask?.cancel()   // real fix arrived — cancel the IP fallback
            self.requestID = UUID()       // invalidate an IP request already in flight
            let id = self.requestID
            // Reverse-geocode for a proper city name
            CLGeocoder().reverseGeocodeLocation(loc) { placemarks, _ in
                guard let city = placemarks?.first?.locality else { return }
                Task { @MainActor in
                    guard self.requestID == id else { return }
                    self.current.city = city
                }
            }
            await self.fetchWeather(lat: loc.coordinate.latitude,
                                    lon: loc.coordinate.longitude,
                                    for: id)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didFailWithError error: Error) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let id = self.beginFallbackRequest()
            await self.fetchViaIP(for: id)
        }
    }

    // MARK: IP fallback

    private func beginFallbackRequest() -> UUID {
        fallbackTask?.cancel()
        requestID = UUID()
        return requestID
    }

    private func fetchViaIP(for id: UUID) async {
        guard requestID == id, !Task.isCancelled else { return }
        guard let url = URL(string: "https://freeipapi.com/api/json") else {
            if requestID == id { status = .error("Location unavailable") }
            return
        }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard requestID == id, !Task.isCancelled else { return }
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                status = .error("Location service unavailable")
                return
            }
            if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let lat = (json["latitude"]  as? NSNumber)?.doubleValue,
               let lon = (json["longitude"] as? NSNumber)?.doubleValue {
                current.city = json["cityName"] as? String ?? ""
                await fetchWeather(lat: lat, lon: lon, for: id)
            } else {
                status = .error("Couldn't determine location")
            }
        } catch {
            guard requestID == id, !Task.isCancelled else { return }
            status = .error(error.localizedDescription)
        }
    }

    // MARK: Fetch & parse (Open-Meteo)

    private func fetchWeather(lat: Double, lon: Double, for id: UUID) async {
        guard requestID == id, !Task.isCancelled else { return }
        var comps = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        comps.queryItems = [
            .init(name: "latitude",  value: String(lat)),
            .init(name: "longitude", value: String(lon)),
            .init(name: "current",   value: "temperature_2m,weather_code"),
            .init(name: "daily",     value: "weather_code,temperature_2m_max,temperature_2m_min"),
            .init(name: "timezone",  value: "auto"),
            .init(name: "forecast_days", value: "5")
        ]
        guard let url = comps.url else { status = .error("Bad URL"); return }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard requestID == id, !Task.isCancelled else { return }
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                status = .error("Weather service error (\(http.statusCode))"); return
            }
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                status = .error("Bad response"); return
            }
            guard parse(json) else {
                status = .error("Incomplete weather response")
                return
            }
            if requestID == id { status = .loaded }
        } catch {
            guard requestID == id, !Task.isCancelled else { return }
            status = .error(error.localizedDescription)
        }
    }

    @discardableResult
    private func parse(_ json: [String: Any]) -> Bool {
        guard let cur = json["current"] as? [String: Any],
              let temperature = cur["temperature_2m"] as? NSNumber,
              let weatherCode = cur["weather_code"] as? NSNumber,
              let daily = json["daily"] as? [String: Any],
              let times = daily["time"] as? [String],
              let codes = daily["weather_code"] as? [NSNumber],
              let maxs = daily["temperature_2m_max"] as? [NSNumber],
              let mins = daily["temperature_2m_min"] as? [NSNumber] else { return false }

        let n = min(times.count, codes.count, maxs.count, mins.count)
        guard n > 0 else { return false }

        current.tempC = Int(temperature.doubleValue.rounded())
        current.code = weatherCode.intValue
        current.desc = Self.desc(for: current.code)

        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        let dayFmt = DateFormatter(); dayFmt.dateFormat = "EEE"
        forecast = (0..<n).map { idx in
            let label: String
            if idx == 0      { label = "Today" }
            else if idx == 1 { label = "Tmrw" }
            else if let date = df.date(from: times[idx]) { label = dayFmt.string(from: date) }
            else             { label = "" }
            return WeatherDay(label: label,
                              maxTemp: Int(maxs[idx].doubleValue.rounded()),
                              minTemp: Int(mins[idx].doubleValue.rounded()),
                              code: codes[idx].intValue)
        }
        return true
    }

    // MARK: WMO code → SF Symbol / tint / description

    static func symbol(for code: Int) -> String {
        switch code {
        case 0:              return "sun.max.fill"
        case 1, 2:           return "cloud.sun.fill"
        case 3:              return "cloud.fill"
        case 45, 48:         return "cloud.fog.fill"
        case 51, 53, 55:     return "cloud.drizzle.fill"
        case 56, 57:         return "cloud.sleet.fill"
        case 61, 80:         return "cloud.rain.fill"
        case 63, 65, 81, 82: return "cloud.heavyrain.fill"
        case 66, 67:         return "cloud.sleet.fill"
        case 71, 73, 75, 77,
             85, 86:         return "cloud.snow.fill"
        case 95:             return "cloud.bolt.fill"
        case 96, 99:         return "cloud.bolt.rain.fill"
        default:             return "cloud.fill"
        }
    }

    static func tint(for code: Int) -> Color {
        switch code {
        case 0:              return .yellow
        case 1, 2:           return Color(white: 0.85)
        case 3:              return Color(white: 0.65)
        case 45, 48:         return Color(white: 0.6)
        case 51, 53, 55, 56, 57,
             61, 63, 65, 66, 67,
             80, 81, 82:     return Color(red: 0.5, green: 0.75, blue: 1.0)
        case 71, 73, 75, 77,
             85, 86:         return Color(white: 0.9)
        case 95, 96, 99:     return Color(red: 0.7, green: 0.7, blue: 1.0)
        default:             return Color(white: 0.7)
        }
    }

    static func desc(for code: Int) -> String {
        switch code {
        case 0:      return "Clear sky"
        case 1:      return "Mainly clear"
        case 2:      return "Partly cloudy"
        case 3:      return "Overcast"
        case 45:     return "Fog"
        case 48:     return "Rime fog"
        case 51:     return "Light drizzle"
        case 53:     return "Drizzle"
        case 55:     return "Heavy drizzle"
        case 56, 57: return "Freezing drizzle"
        case 61:     return "Light rain"
        case 63:     return "Rain"
        case 65:     return "Heavy rain"
        case 66, 67: return "Freezing rain"
        case 71:     return "Light snow"
        case 73:     return "Snow"
        case 75:     return "Heavy snow"
        case 77:     return "Snow grains"
        case 80:     return "Light showers"
        case 81:     return "Showers"
        case 82:     return "Violent showers"
        case 85:     return "Snow showers"
        case 86:     return "Heavy snow showers"
        case 95:     return "Thunderstorm"
        case 96, 99: return "Thunderstorm, hail"
        default:     return ""
        }
    }
}

// MARK: - Expanded weather view

struct WeatherView: View {
    @EnvironmentObject var state: PillState
    @StateObject private var monitor = WeatherMonitor.shared

    var body: some View {
        Group {
            switch monitor.status {
            case .idle, .loading:
                VStack(spacing: 8) {
                    ProgressView().scaleEffect(0.7).colorScheme(.dark)
                    Text("Fetching weather…").font(.system(size: 11)).foregroundColor(.white.opacity(0.5))
                }
            case .error(let msg):
                VStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 18)).foregroundColor(.orange.opacity(0.7))
                    Text(msg).font(.system(size: 9)).foregroundColor(.white.opacity(0.45))
                        .multilineTextAlignment(.center).lineLimit(2)
                    Button { monitor.refresh() } label: {
                        Text("Retry").font(.system(size: 10, weight: .medium))
                            .foregroundColor(.white.opacity(0.6))
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .background(Capsule().fill(Color.white.opacity(0.08)))
                    }.buttonStyle(.plain)
                }
            case .loaded:
                loadedView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { if monitor.status == .idle { monitor.refresh() } }
    }

    var loadedView: some View {
        VStack(spacing: 10) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: WeatherMonitor.symbol(for: monitor.current.code))
                    .font(.system(size: 34, weight: .thin))
                    .foregroundColor(WeatherMonitor.tint(for: monitor.current.code))
                    .shadow(color: WeatherMonitor.tint(for: monitor.current.code).opacity(0.5), radius: 8)
                    .frame(width: 42)

                VStack(alignment: .leading, spacing: 2) {
                    Text(state.temp(monitor.current.tempC))
                        .font(.system(size: 30, weight: .thin, design: .rounded))
                        .foregroundColor(.white)
                    Text(monitor.current.desc)
                        .font(.system(size: 10)).foregroundColor(.white.opacity(0.55))
                    if !monitor.current.city.isEmpty {
                        HStack(spacing: 3) {
                            Image(systemName: "location.fill").font(.system(size: 7))
                            Text(monitor.current.city).font(.system(size: 9))
                        }.foregroundColor(.white.opacity(0.38))
                    }
                }
                Spacer()
                Button { monitor.refresh() } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10)).foregroundColor(.white.opacity(0.3))
                }.buttonStyle(.plain)
            }

            HStack(spacing: 0) {
                ForEach(monitor.forecast) { day in
                    VStack(spacing: 3) {
                        Text(day.label)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(.white.opacity(0.4))
                        Image(systemName: WeatherMonitor.symbol(for: day.code))
                            .font(.system(size: 13))
                            .foregroundColor(WeatherMonitor.tint(for: day.code))
                        Text(state.temp(day.maxTemp))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.white.opacity(0.8))
                        Text(state.temp(day.minTemp))
                            .font(.system(size: 9))
                            .foregroundColor(.white.opacity(0.38))
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.05)))
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 20)
    }
}
