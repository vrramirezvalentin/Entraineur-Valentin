import SwiftUI
import MapKit
import UIKit

/// Le point qui avance sur le parcours.
final class RunnerAnnotation: NSObject, MKAnnotation {
    @objc dynamic var coordinate: CLLocationCoordinate2D

    init(coordinate: CLLocationCoordinate2D) {
        self.coordinate = coordinate
    }
}

final class RunnerDotView: MKAnnotationView {
    static let reuseID = "runner"

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        frame = CGRect(x: 0, y: 0, width: 40, height: 40)
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = false
        canShowCallout = false
        displayPriority = .required
        zPriority = .max
        collisionMode = .circle
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) n'est pas utilisé")
    }

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        func circle(_ diameter: CGFloat, _ color: UIColor) {
            ctx.setFillColor(color.cgColor)
            ctx.fillEllipse(in: CGRect(x: center.x - diameter / 2, y: center.y - diameter / 2,
                                       width: diameter, height: diameter))
        }
        circle(38, UIColor.systemOrange.withAlphaComponent(0.3))
        ctx.setShadow(offset: CGSize(width: 0, height: 1), blur: 3,
                      color: UIColor.black.withAlphaComponent(0.35).cgColor)
        circle(20, .white)
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
        circle(13, .systemOrange)
    }
}

/// Pilote la carte 3D : tracé, point, caméra. Tout passe par `show(...)`, appelé à chaque image.
@MainActor
final class FlyoverMapController: NSObject, MKMapViewDelegate {
    let mapView = MKMapView(frame: .zero)

    private var runner: RunnerAnnotation?
    private var basePolyline: MKPolyline?
    private var donePolyline: MKPolyline?
    private var doneRenderer: MKPolylineRenderer?
    private var stroke: CGFloat = 0
    private var loading = false
    private var rendering = false

    /// Vrai tant que la carte charge ou dessine des tuiles.
    var isBusy: Bool { loading || rendering }

    /// À appeler une fois, juste après la création.
    func configure() {
        mapView.delegate = self
        mapView.showsCompass = false
        mapView.showsScale = false
        mapView.showsUserLocation = false
        mapView.isPitchEnabled = true
        mapView.isRotateEnabled = true
        mapView.register(RunnerDotView.self, forAnnotationViewWithReuseIdentifier: RunnerDotView.reuseID)
        setSatellite(true)
    }

    func setSatellite(_ satellite: Bool) {
        if satellite {
            mapView.preferredConfiguration = MKImageryMapConfiguration(elevationStyle: .realistic)
        } else {
            let standard = MKStandardMapConfiguration(elevationStyle: .realistic)
            standard.pointOfInterestFilter = .excludingAll
            mapView.preferredConfiguration = standard
        }
    }

    /// Installe le tracé et le point pour un parcours.
    func load(_ route: FlyoverRoute) {
        mapView.removeOverlays(mapView.overlays)
        mapView.removeAnnotations(mapView.annotations)
        doneRenderer = nil
        stroke = 0

        let coordinates = route.points.map(\.coordinate)
        let base = MKPolyline(coordinates: coordinates, count: coordinates.count)
        let done = MKPolyline(coordinates: coordinates, count: coordinates.count)
        basePolyline = base
        donePolyline = done
        mapView.addOverlay(base, level: .aboveLabels)
        mapView.addOverlay(done, level: .aboveLabels)

        let annotation = RunnerAnnotation(coordinate: coordinates.first ?? CLLocationCoordinate2D())
        runner = annotation
        mapView.addAnnotation(annotation)
        mapView.setCamera(route.overview.mapCamera, animated: false)
    }

    /// Place la caméra, le point et la partie déjà parcourue du tracé.
    func show(camera: FlyCam, runnerAt coordinate: CLLocationCoordinate2D, stroke newStroke: Double) {
        mapView.setCamera(camera.mapCamera, animated: false)
        runner?.coordinate = coordinate

        let target = CGFloat(min(1, max(0, newStroke)))
        if target != stroke {
            stroke = target
            if let doneRenderer {
                doneRenderer.strokeEnd = target
                doneRenderer.setNeedsDisplay()
            }
        }
    }

    // MARK: MKMapViewDelegate

    func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
        guard let polyline = overlay as? MKPolyline else { return MKOverlayRenderer(overlay: overlay) }
        let renderer = MKPolylineRenderer(polyline: polyline)
        renderer.lineCap = .round
        renderer.lineJoin = .round
        if polyline === donePolyline {
            renderer.strokeColor = .systemOrange
            renderer.lineWidth = 7
            renderer.strokeEnd = stroke
            doneRenderer = renderer
        } else {
            renderer.strokeColor = UIColor.white.withAlphaComponent(0.6)
            renderer.lineWidth = 4
        }
        return renderer
    }

    func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
        guard annotation is RunnerAnnotation else { return nil }
        return mapView.dequeueReusableAnnotationView(withIdentifier: RunnerDotView.reuseID, for: annotation)
    }

    func mapViewWillStartLoadingMap(_ mapView: MKMapView) { loading = true }
    func mapViewDidFinishLoadingMap(_ mapView: MKMapView) { loading = false }
    func mapViewDidFailLoadingMap(_ mapView: MKMapView, withError error: Error) { loading = false }
    func mapViewWillStartRenderingMap(_ mapView: MKMapView) { rendering = true }
    func mapViewDidFinishRenderingMap(_ mapView: MKMapView, fullyRendered: Bool) { rendering = false }
}

/// La carte 3D dans SwiftUI.
struct FlyoverMapView: UIViewRepresentable {
    let controller: FlyoverMapController

    func makeUIView(context: Context) -> MKMapView {
        controller.mapView
    }

    func updateUIView(_ mapView: MKMapView, context: Context) {}
}
