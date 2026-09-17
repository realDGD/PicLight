import Foundation
import CoreGraphics
import ImageIO

/// Reads display metadata. Values only, so the result can cross actor boundaries.
public enum MetadataReader {
    public static func read(source: CGImageSource, url: URL, index: Int = 0) -> ImageMetadata {
        let properties = (CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]) ?? [:]
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let gps = properties[kCGImagePropertyGPSDictionary] as? [CFString: Any] ?? [:]
        let fileAttributes = try? FileManager.default.attributesOfItem(atPath: url.path)

        let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue
        let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue
        let depth = (properties[kCGImagePropertyDepth] as? NSNumber)?.intValue
        let profileName = (properties[kCGImagePropertyProfileName] as? String)
        let colorModel = (properties[kCGImagePropertyColorModel] as? String)

        var fields: [String: String] = [:]
        if let width, let height { fields["像素尺寸"] = "\(width) × \(height)" }
        if let depth { fields["位深度"] = "\(depth) bit" }
        if let profileName { fields["颜色配置文件"] = profileName }
        if let colorModel { fields["颜色模型"] = colorModel }
        if let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue {
            fields["方向"] = "\(orientation)"
        }
        if let size = (fileAttributes?[.size] as? NSNumber)?.int64Value {
            fields["文件大小"] = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
        }

        let exposureTime = exif[kCGImagePropertyExifExposureTime] as? Double
        let aperture = exif[kCGImagePropertyExifFNumber] as? Double
        let isoValues = (exif[kCGImagePropertyExifISOSpeedRatings] as? [NSNumber])?.map(\.intValue) ?? []
        let focalLength = exif[kCGImagePropertyExifFocalLength] as? Double
        let exposureBias = exif[kCGImagePropertyExifExposureBiasValue] as? Double
        let captureDate = exif[kCGImagePropertyExifDateTimeOriginal] as? String

        if let exposureTime {
            fields["快门"] = exposureTime >= 1
                ? String(format: "%.1f s", exposureTime)
                : "1/\(Int((1 / exposureTime).rounded())) s"
        }
        if let aperture { fields["光圈"] = String(format: "f/%.1f", aperture) }
        if !isoValues.isEmpty { fields["ISO"] = isoValues.map(String.init).joined(separator: ", ") }
        if let focalLength { fields["焦距"] = String(format: "%.0f mm", focalLength) }
        if let exposureBias, exposureBias != 0 {
            fields["曝光补偿"] = String(format: "%+.1f EV", exposureBias)
        }
        if let captureDate { fields["拍摄时间"] = captureDate }

        let make = tiff[kCGImagePropertyTIFFMake] as? String
        let model = tiff[kCGImagePropertyTIFFModel] as? String
        let lens = exif[kCGImagePropertyExifLensModel] as? String
        if let make { fields["相机品牌"] = make }
        if let model { fields["相机型号"] = model }
        if let lens { fields["镜头"] = lens }

        let latitude = (gps[kCGImagePropertyGPSLatitude] as? NSNumber)?.doubleValue
        let longitude = (gps[kCGImagePropertyGPSLongitude] as? NSNumber)?.doubleValue
        let altitude = (gps[kCGImagePropertyGPSAltitude] as? NSNumber)?.doubleValue
        if latitude != nil || longitude != nil {
            let lat = latitude.map { String(format: "%.5f", $0) } ?? "-"
            let lon = longitude.map { String(format: "%.5f", $0) } ?? "-"
            fields["GPS"] = "\(lat), \(lon)"
        }

        return ImageMetadata(
            fileName: url.lastPathComponent,
            fileSize: (fileAttributes?[.size] as? NSNumber)?.int64Value,
            creationDate: fileAttributes?[.creationDate] as? Date,
            modificationDate: fileAttributes?[.modificationDate] as? Date,
            colorSpace: profileName ?? colorModel,
            bitDepth: depth,
            captureDate: captureDate,
            cameraMake: make,
            cameraModel: model,
            lensModel: lens,
            focalLength: focalLength,
            aperture: aperture,
            exposureTime: exposureTime,
            iso: isoValues,
            exposureCompensation: exposureBias,
            latitude: latitude,
            longitude: longitude,
            altitude: altitude,
            fields: fields
        )
    }
}
