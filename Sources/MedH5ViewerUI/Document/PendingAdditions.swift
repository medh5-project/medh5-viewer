import Foundation
import MedH5Kit

/// An image added in the viewer (Import ▸ NIfTI Image…), written at the
/// next save.
public struct NewImage: @unchecked Sendable, Equatable {
    /// The grid it lies on: one the file holds or one in `newGrids`.
    public var grid: String
    /// Its samples, every axis of the grid's shape, in the stored type.
    public var data: VolumeData
    public var options: ImageWriteOptions
    /// The file it was read from (shown in the sidebar).
    public var source: String?

    public init(grid: String, data: VolumeData, options: ImageWriteOptions, source: String? = nil) {
        self.grid = grid
        self.data = data
        self.options = options
        self.source = source
    }

    public static func == (a: NewImage, b: NewImage) -> Bool {
        a.grid == b.grid && a.data === b.data && a.options == b.options && a.source == b.source
    }
}

/// A segmentation imported from NIfTI (Import ▸ NIfTI Segmentation…): its
/// layers as read, written at the next save with the coverage the import
/// chose.
public struct ImportedSegmentation: @unchecked Sendable, Equatable {
    public var grid: String
    /// `uint16` layers over the grid's spatial shape.
    public var layers: [VolumeData]
    public var options: SegmentationWriteOptions
    public var source: String?

    public init(grid: String, layers: [VolumeData], options: SegmentationWriteOptions, source: String? = nil) {
        self.grid = grid
        self.layers = layers
        self.options = options
        self.source = source
    }

    public static func == (a: ImportedSegmentation, b: ImportedSegmentation) -> Bool {
        a.grid == b.grid && a.options == b.options && a.source == b.source
            && a.layers.count == b.layers.count && zip(a.layers, b.layers).allSatisfy { $0 === $1 }
    }
}

extension PendingEdits {
    /// Writes what the viewer added: grids first, then the images and
    /// segmentations on them. The save calls this after the document and
    /// label set (a new grid's timepoint and an imported segmentation's
    /// classes are declared there) and before edited segmentations.
    func writeAdditions(to writer: SampleWriter) throws {
        for (id, grid) in newGrids.sorted(by: { $0.key < $1.key }) {
            var g = grid
            g.id = id
            try writer.addGrid(g)
        }
        for (id, image) in newImages.sorted(by: { $0.key < $1.key }) where !removedImages.contains(id) {
            try writer.addImage(id: id, grid: image.grid, data: image.data, options: image.options)
        }
        for (id, s) in importedSegmentations.sorted(by: { $0.key < $1.key }) where !removedAnnotations.contains(id) {
            try writer.addSegmentation(id: id, grid: s.grid, layers: s.layers, options: s.options)
        }
    }

    /// After a save: what it wrote is no longer pending (an addition made
    /// while it wrote stays).
    mutating func forgetSavedAdditions(_ saved: PendingEdits) {
        for (id, g) in saved.newGrids where newGrids[id] == g { newGrids[id] = nil }
        for (id, i) in saved.newImages where newImages[id] == i { newImages[id] = nil }
        for (id, s) in saved.importedSegmentations where importedSegmentations[id] == s { importedSegmentations[id] = nil }
    }
}
