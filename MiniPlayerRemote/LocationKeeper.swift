import CoreLocation
import Foundation

final class LocationKeeper: NSObject, ObservableObject {
    @Published var status: String = "Location: idle"

    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.distanceFilter = 100
        manager.allowsBackgroundLocationUpdates = false
        manager.pausesLocationUpdatesAutomatically = false
    }

    func start() {
        status = "Location: requesting authorization"
        manager.requestAlwaysAuthorization()
        updateStatus(for: manager.authorizationStatus)
        manager.startUpdatingLocation()
    }

    func stop() {
        manager.stopUpdatingLocation()
        status = "Location: stopped"
    }
}

extension LocationKeeper: CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        updateStatus(for: manager.authorizationStatus)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        status = "Location error: \(error.localizedDescription)"
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard locations.last != nil else { return }
        status = "Location: active"
    }

    private func updateStatus(for status: CLAuthorizationStatus) {
        switch status {
        case .authorizedAlways:
            self.status = "Location: active (Always)"
            manager.allowsBackgroundLocationUpdates = true
            manager.startUpdatingLocation()
        case .authorizedWhenInUse:
            self.status = "Location: active (When In Use)"
            manager.allowsBackgroundLocationUpdates = false
            manager.startUpdatingLocation()
        case .denied:
            self.status = "Location: denied"
            manager.allowsBackgroundLocationUpdates = false
        case .restricted:
            self.status = "Location: restricted"
            manager.allowsBackgroundLocationUpdates = false
        case .notDetermined:
            self.status = "Location: not determined"
            manager.allowsBackgroundLocationUpdates = false
        @unknown default:
            self.status = "Location: unknown"
            manager.allowsBackgroundLocationUpdates = false
        }
    }
}
