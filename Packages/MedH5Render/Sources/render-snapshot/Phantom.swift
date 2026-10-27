import Foundation
import simd
import MedH5Core

/// A synthetic CT-like torso in LPS world coordinates (mm; x = patient left,
/// y = posterior, z = superior), with organ and lesion segmentations in two
/// label layers (overlapping between layers), a PET-like volume and a
/// probability map on their own grids, all in one frame.
struct Phantom {
    let ct: ImageVolume
    let organs: VolumeData          // uint16 on the CT grid
    let lesions: VolumeData         // uint16 on the CT grid (overlaps organs)
    let pet: ImageVolume            // float32 SUV on a coarse, slightly rotated grid
    let probability: ImageVolume    // float32 0…1 on a 2 mm grid
    let lesionCenter: SIMD3<Double>
    let lesionRadius: Double

    var grid: GridGeometry { ct.geometry }

    enum Organ: UInt16 {
        case liver = 1, leftLung = 2, rightLung = 3, heart = 4, spine = 5, leftKidney = 6, rightKidney = 7, aorta = 8, spleen = 9
    }
    static let lesionClass: UInt16 = 10
    static let rimClass: UInt16 = 11

    static let organNames: [UInt16: String] = [
        1: "liver", 2: "left lung", 3: "right lung", 4: "heart", 5: "spine", 6: "left kidney", 7: "right kidney",
        8: "aorta", 9: "spleen", 10: "lesion", 11: "lesion rim",
    ]

    /// `shape` is (z, y, x) — slices, rows, columns.
    /// With `partialVolume`, each voxel's value averages 2 × 2 × 2 sub-samples,
    /// as a scanner's finite resolution would (labels come from the centre).
    static func make(shape: SIMD3<Int> = SIMD3(120, 256, 256), spacing: SIMD3<Double> = SIMD3(2.0, 0.9, 0.9),
                     noise: Bool = true, partialVolume: Bool = true) -> Phantom {
        let n = shape
        let origin = SIMD3(-Double(n.z - 1) / 2 * spacing.z, -Double(n.y - 1) / 2 * spacing.y,
                           -Double(n.x - 1) / 2 * spacing.x)   // world (x, y, z) of index 0
        let grid = GridGeometry(id: "ct", shape: [n.x, n.y, n.z], spacing: [spacing.x, spacing.y, spacing.z],
                                origin: [origin.x, origin.y, origin.z],
                                direction: [[0, 0, 1], [0, 1, 0], [1, 0, 0]], frameUID: "phantom-frame")
        let ctData = VolumeData(scalarType: .int16, shape: [n.x, n.y, n.z])
        let organs = VolumeData(scalarType: .uint16, shape: [n.x, n.y, n.z])
        let lesions = VolumeData(scalarType: .uint16, shape: [n.x, n.y, n.z])
        let lesionCenter = SIMD3<Double>(-52, -8, -40)
        let lesionRadius = 13.0
        let hu = ctData.pointer(as: Int16.self)
        let org = organs.pointer(as: UInt16.self)
        let les = lesions.pointer(as: UInt16.self)
        let m = grid.indexToWorld
        // Noise-free values at voxel centres first; then voxels on a tissue
        // boundary (a 6-neighbour differs) average 2 × 2 × 2 sub-samples.
        let count = n.x * n.y * n.z
        let centre = UnsafeMutablePointer<Float>.allocate(capacity: count)
        defer { centre.deallocate() }
        DispatchQueue.concurrentPerform(iterations: n.x) { k0 in
            for k1 in 0..<n.y {
                for k2 in 0..<n.z {
                    let w = m.transformPoint(SIMD3(Double(k0), Double(k1), Double(k2)))
                    let i = (k0 * n.y + k1) * n.z + k2
                    let (value, organ, lesion) = Phantom.tissue(at: w, lesionCenter: lesionCenter,
                                                                lesionRadius: lesionRadius)
                    centre[i] = Float(value)
                    org[i] = organ
                    les[i] = lesion
                }
            }
        }
        DispatchQueue.concurrentPerform(iterations: n.x) { k0 in
            for k1 in 0..<n.y {
                for k2 in 0..<n.z {
                    let i = (k0 * n.y + k1) * n.z + k2
                    var v = Double(centre[i])
                    if partialVolume {
                        let c = centre[i]
                        let edge = (k0 > 0 && centre[i - n.y * n.z] != c) || (k0 < n.x - 1 && centre[i + n.y * n.z] != c)
                            || (k1 > 0 && centre[i - n.z] != c) || (k1 < n.y - 1 && centre[i + n.z] != c)
                            || (k2 > 0 && centre[i - 1] != c) || (k2 < n.z - 1 && centre[i + 1] != c)
                        if edge {
                            v = 0
                            for s in 0..<8 {
                                let o = SIMD3(Double(s & 1), Double((s >> 1) & 1), Double((s >> 2) & 1)) * 0.5 - 0.25
                                let q = m.transformPoint(SIMD3(Double(k0), Double(k1), Double(k2)) + o)
                                v += Phantom.tissue(at: q, lesionCenter: lesionCenter, lesionRadius: lesionRadius).0
                            }
                            v /= 8
                        }
                    }
                    if noise && v > -950 { v += Phantom.gaussianNoise(i) * 9 }
                    hu[i] = Int16(clampingDouble: v)
                }
            }
        }
        let ct = ImageVolume(id: "ct", data: ctData, geometry: grid, modality: "CT",
                             windowPresets: [WindowPreset(name: "Soft tissue", center: 40, width: 400)])

        // PET: 4 mm voxels, a different origin and a 4° rotation, same frame.
        let petN = 64
        var petGrid = GridGeometry(id: "pet", shape: [petN, petN, petN], spacing: [4, 4, 4],
                                   direction: Phantom.rotation(axis: SIMD3(0.2, 0.3, 1), degrees: 4),
                                   frameUID: "phantom-frame")
        let petShift = SIMD3<Double>(3, -2, 1) - petGrid.worldCenter
        petGrid.origin = [petShift.x, petShift.y, petShift.z]
        let petData = VolumeData(scalarType: .float32, shape: [petN, petN, petN])
        let petPtr = petData.pointer(as: Float.self)
        let pm = petGrid.indexToWorld
        DispatchQueue.concurrentPerform(iterations: petN) { a in
            for b in 0..<petN {
                for c in 0..<petN {
                    let w = pm.transformPoint(SIMD3(Double(a), Double(b), Double(c)))
                    petPtr[(a * petN + b) * petN + c] = Float(Phantom.uptake(at: w, lesionCenter: lesionCenter))
                }
            }
        }
        let pet = ImageVolume(id: "pet", data: petData, geometry: petGrid, modality: "PT", valueUnits: "SUV")

        // Probability of the lesion: a soft blob on a 2 mm grid around it.
        let pn = SIMD3(36, 36, 36)
        var probGrid = GridGeometry(id: "prob", shape: [pn.x, pn.y, pn.z], spacing: [2, 2, 2],
                                    direction: [[0, 0, 1], [0, 1, 0], [1, 0, 0]], frameUID: "phantom-frame")
        let probShift = lesionCenter - probGrid.worldCenter
        probGrid.origin = [probShift.x, probShift.y, probShift.z]
        let probData = VolumeData(scalarType: .float32, shape: [pn.x, pn.y, pn.z])
        let pp = probData.pointer(as: Float.self)
        let qm = probGrid.indexToWorld
        for a in 0..<pn.x {
            for b in 0..<pn.y {
                for c in 0..<pn.z {
                    let w = qm.transformPoint(SIMD3(Double(a), Double(b), Double(c)))
                    let d = w - lesionCenter
                    // An anisotropic blob, larger than the lesion, so contours differ from its outline.
                    let r = simd_length(d / SIMD3(1.35, 1.0, 1.15))
                    pp[(a * pn.y + b) * pn.z + c] = Float(1 / (1 + exp((r - lesionRadius - 2) / 2.2)))
                }
            }
        }
        let probability = ImageVolume(id: "prob", data: probData, geometry: probGrid, valueType: "probability")
        return Phantom(ct: ct, organs: organs, lesions: lesions, pet: pet, probability: probability,
                       lesionCenter: lesionCenter, lesionRadius: lesionRadius)
    }

    // MARK: Anatomy

    private static func ellipsoid(_ p: SIMD3<Double>, _ c: SIMD3<Double>, _ r: SIMD3<Double>) -> Double {
        simd_length_squared((p - c) / r)
    }

    /// HU, organ class, lesion class at a world point.
    static func tissue(at p: SIMD3<Double>, lesionCenter: SIMD3<Double>, lesionRadius: Double) -> (Double, UInt16, UInt16) {
        let z = p.z
        // Body: an elliptic cylinder tapering towards the ends.
        let taper = max(0, 1 - pow(z / 125, 2)).squareRoot()
        let rx = 105 * taper, ry = 78 * taper
        guard rx > 1, abs(z) < 118 else { return (-1000, 0, 0) }
        let e = pow(p.x / rx, 2) + pow((p.y - 5) / ry, 2)
        if e > 1 { return (-1000, 0, 0) }
        let depth = (1 - e.squareRoot()) * min(rx, ry)   // approximate distance below the skin
        var value = 40.0
        var organ: UInt16 = 0
        var lesion: UInt16 = 0
        if depth < 1.5 { value = 10 } else if depth < 9 { value = -95 }

        // Ribs: a ring of bone under the fat in the chest.
        if z > -20 && z < 95 && depth > 9 && depth < 15 {
            let phase = (z + 200).truncatingRemainder(dividingBy: 24)
            if phase < 9 && p.y < 45 { value = 450 }
        }
        // Lungs.
        for (side, cls) in [(1.0, Organ.leftLung), (-1.0, Organ.rightLung)] {
            if ellipsoid(p, SIMD3(side * 48, 0, 40), SIMD3(36, 46, 62)) < 1 {
                value = -840
                organ = cls.rawValue
                // Vessels branching in the lung.
                let v1 = simd_length(SIMD2(p.x - side * 40, p.y + 5))
                let v2 = simd_length(SIMD2(p.x - side * (40 + (z - 40) * 0.35), p.y - 12))
                if v1 < 2.4 || (v2 < 1.8 && z > 30) { value = 60 }
            }
        }
        // Heart with a contrast-filled ventricle.
        if ellipsoid(p, SIMD3(-14, -22, 8), SIMD3(42, 36, 38)) < 1 {
            organ = Organ.heart.rawValue
            value = ellipsoid(p, SIMD3(-22, -24, 8), SIMD3(18, 16, 20)) < 1 ? 280 : 55
        }
        // Liver with the lesion.
        if ellipsoid(p, SIMD3(-48, -5, -42), SIMD3(56, 50, 38)) < 1 && z < 0 {
            organ = Organ.liver.rawValue
            value = 62
            let d = simd_distance(p, lesionCenter)
            if d < lesionRadius {
                value = d < lesionRadius - 3 ? 105 : 85
                lesion = d < lesionRadius - 3 ? Phantom.lesionClass : Phantom.rimClass
            }
        }
        // Spleen.
        if ellipsoid(p, SIMD3(62, 25, -35), SIMD3(18, 28, 26)) < 1 {
            organ = Organ.spleen.rawValue
            value = 48
        }
        // Kidneys.
        for (side, cls) in [(1.0, Organ.leftKidney), (-1.0, Organ.rightKidney)] {
            if ellipsoid(p, SIMD3(side * 52, 38, -72), SIMD3(17, 14, 30)) < 1 {
                organ = cls.rawValue
                value = ellipsoid(p, SIMD3(side * 50, 38, -72), SIMD3(8, 7, 18)) < 1 ? 20 : 160
            }
        }
        // Aorta.
        if simd_length(SIMD2(p.x - 12, p.y - 22)) < 11 && z < 60 && z > -110 {
            organ = Organ.aorta.rawValue
            value = 260
        }
        // Spine: vertebral bodies with discs, a spinal canal.
        let spine = simd_length(SIMD2(p.x, p.y - 52))
        if spine < 16 {
            let disc = (z + 300).truncatingRemainder(dividingBy: 28) < 5
            organ = Organ.spine.rawValue
            value = disc ? 70 : (spine > 13 ? 750 : 260)
        }
        if simd_length(SIMD2(p.x, p.y - 74)) < 7 && z < 110 { value = 15 }   // spinal canal / cord
        // Calibration spheres in the pelvis.
        for (i, v) in [200.0, 400.0, 800.0, 1200.0].enumerated() {
            if simd_distance(p, SIMD3(-54 + Double(i) * 36, -20, -100)) < 8 { value = v }
        }
        return (value, organ, lesion)
    }

    /// SUV at a world point.
    static func uptake(at p: SIMD3<Double>, lesionCenter: SIMD3<Double>) -> Double {
        let (value, organ, lesion) = tissue(at: p, lesionCenter: lesionCenter, lesionRadius: 13)
        if value <= -950 { return 0 }
        var suv = 0.8
        switch organ {
        case Organ.liver.rawValue: suv = 2.2
        case Organ.heart.rawValue: suv = 4.5
        case Organ.leftKidney.rawValue, Organ.rightKidney.rawValue: suv = 6
        case Organ.leftLung.rawValue, Organ.rightLung.rawValue: suv = 0.4
        case Organ.spine.rawValue: suv = 1.6
        default: break
        }
        if lesion != 0 { suv = 9 }
        // Blur the lesion's uptake a little beyond its edge (partial volume).
        let d = simd_distance(p, lesionCenter)
        suv = max(suv, 9 * exp(-pow(max(0, d - 10) / 7, 2)))
        return suv
    }

    /// Deterministic noise with a roughly unit normal distribution.
    static func gaussianNoise(_ i: Int) -> Double {
        func hash(_ x: UInt64) -> Double {
            var z = x &+ 0x9E3779B97F4A7C15
            z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
            z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
            z ^= z >> 31
            return Double(z >> 11) / Double(1 << 53)
        }
        let u = UInt64(i) &* 3
        return (hash(u) + hash(u + 1) + hash(u + 2) - 1.5) * 2
    }

    static func rotation(axis: SIMD3<Double>, degrees: Double) -> [[Double]] {
        let q = simd_quatd(angle: degrees * .pi / 180, axis: simd_normalize(axis))
        let m = simd_double3x3(q)
        return (0..<3).map { r in (0..<3).map { c in m[c][r] } }
    }
}
