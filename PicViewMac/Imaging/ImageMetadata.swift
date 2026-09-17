import Foundation

/// Value-only metadata is safe to pass from background decoders to AppKit.
public struct ImageMetadata: Sendable, Equatable {
    public var fileName: String
    public var fileSize: Int64?
    public var creationDate: Date?
    public var modificationDate: Date?
    public var colorSpace: String?
    public var bitDepth: Int?
    public var captureDate: String?
    public var cameraMake: String?
    public var cameraModel: String?
    public var lensModel: String?
    public var focalLength: Double?
    public var aperture: Double?
    public var exposureTime: Double?
    public var iso: [Int]
    public var exposureCompensation: Double?
    public var latitude: Double?
    public var longitude: Double?
    public var altitude: Double?
    /// Sorted string fields for a generic read-only information panel.
    public var fields: [String: String]

    public init(fileName: String = "", fileSize: Int64? = nil,
                creationDate: Date? = nil, modificationDate: Date? = nil,
                colorSpace: String? = nil, bitDepth: Int? = nil,
                captureDate: String? = nil, cameraMake: String? = nil,
                cameraModel: String? = nil, lensModel: String? = nil,
                focalLength: Double? = nil, aperture: Double? = nil,
                exposureTime: Double? = nil, iso: [Int] = [],
                exposureCompensation: Double? = nil, latitude: Double? = nil,
                longitude: Double? = nil, altitude: Double? = nil,
                fields: [String: String] = [:]) {
        self.fileName = fileName; self.fileSize = fileSize
        self.creationDate = creationDate; self.modificationDate = modificationDate
        self.colorSpace = colorSpace; self.bitDepth = bitDepth
        self.captureDate = captureDate; self.cameraMake = cameraMake
        self.cameraModel = cameraModel; self.lensModel = lensModel
        self.focalLength = focalLength; self.aperture = aperture
        self.exposureTime = exposureTime; self.iso = iso
        self.exposureCompensation = exposureCompensation
        self.latitude = latitude; self.longitude = longitude; self.altitude = altitude
        self.fields = fields
    }
}
