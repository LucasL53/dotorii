//
//  DataModel.swift
//  FinSight
//
//  Created by Yunseo Lee on 9/16/23.
//

import AVFoundation
import SwiftUI
import os.log
import Vision
import PythonKit

final class DataModel: ObservableObject {
    let camera = Camera()
    let photoCollection = PhotoCollection(smartAlbum: .smartAlbumUserLibrary)

    let ocr = OCRViewModel()
    let api = LLM_API()
    let dirpath = "/Users/yunseolee/Documents/Github/dotorii/dotorii/dotorii/AI"
    
    @Published var viewfinderImage: Image?
    @Published var thumbnailImage: Image?
    @Published var recognizedText: String = ""
    private var output = ""
    
    var didDetectDocument = false
    var isPhotosLoaded = false
    
    private var stableDocumentCounter = 0
    
    init() {
        Task {
            await handleCameraPreviews()
        }
        
        Task {
            await handleCameraPhotos()
        }
    }
    
    func runPythonCode(input: String){
      let sys = Python.import("sys")
      sys.path.append(dirpath)
      let example = Python.import("googleCalendar")
      let response = example.create_event("DUBHACK \'23", "Explore limitless imagination in tech\'s ever-changing world. Join us at \'Beyond Imaginable,\' the largest collegiate hackathon in the PNW, where boundaries blur and possibilities bloom.", "2023-10-14T00:00:00", "2023-10-15T23:59:59", "University of Washington, Seattle")
    }

    func handleCameraPreviews() async {
        let imageStream = camera.previewStream
            .map { $0.image }

        for await image in imageStream {
            Task { @MainActor in
                viewfinderImage = image
            }
        }
    }
    
    // In DataModel.swift
    func fetchOutput() -> String {
        return !output.isEmpty ? output : "No API output"
    }

    func handleCameraPhotos() async {
        let unpackedPhotoStream = camera.photoStream.compactMap { photo in
            self.unpackPhoto(photo)
        }

        for await photoData in unpackedPhotoStream {
            // Update the thumbnail image
            thumbnailImage = photoData.thumbnailImage

            // Perform OCR detection on the high-resolution image data
            recognizeText(from: photoData.imageData) { recognizedText in
                if let text = recognizedText, !text.isEmpty {
                    // Store the recognized text or process it further
                    self.recognizedText = text
                    self.output = self.api.runQuery(poster: self.recognizedText)
                    print(self.output)
                    self.runPythonCode(input: self.output)
                }
            }

            // Save the photo to the photo library
            do {
                try await photoCollection.addImage(photoData.imageData)
            } catch {
                print("Error saving photo: \(error.localizedDescription)")
                // Handle the error further if needed, e.g., show an alert to the user
            }
        }
    }

    func recognizeText(from imageData: Data, completion: @escaping (String?) -> Void) {
        guard let cgImage = UIImage(data: imageData)?.cgImage else {
            completion(nil)
            return
        }

        let request = VNRecognizeTextRequest { request, error in
            guard let observations = request.results as? [VNRecognizedTextObservation], error == nil else {
                completion(nil)
                return
            }
            
            let text = observations.compactMap({
                $0.topCandidates(1).first?.string
            }).joined(separator: " ")
            
            completion(text)
        }

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            print("Error on text recognition: \(error)")
            completion(nil)
        }
    }

    
    private func unpackPhoto(_ photo: AVCapturePhoto) -> PhotoData? {
        guard let imageData = photo.fileDataRepresentation() else { return nil }

        guard let previewCGImage = photo.previewCGImageRepresentation(),
           let metadataOrientation = photo.metadata[String(kCGImagePropertyOrientation)] as? UInt32,
              let cgImageOrientation = CGImagePropertyOrientation(rawValue: metadataOrientation) else { return nil }
        let imageOrientation = Image.Orientation(cgImageOrientation)
        let thumbnailImage = Image(decorative: previewCGImage, scale: 1, orientation: imageOrientation)
        
        let photoDimensions = photo.resolvedSettings.photoDimensions
        let imageSize = (width: Int(photoDimensions.width), height: Int(photoDimensions.height))
        let previewDimensions = photo.resolvedSettings.previewDimensions
        let thumbnailSize = (width: Int(previewDimensions.width), height: Int(previewDimensions.height))
        
        return PhotoData(thumbnailImage: thumbnailImage, thumbnailSize: thumbnailSize, imageData: imageData, imageSize: imageSize)
    }
    
    func savePhoto(imageData: Data) {
        Task {
            do {
                try await photoCollection.addImage(imageData)
                
                logger.debug("Added image data to photo collection.")
            } catch let error {
                logger.error("Failed to add image to photo collection: \(error.localizedDescription)")
            }
        }
    }
    
    func loadPhotos() async {
        guard !isPhotosLoaded else { return }
        
        let authorized = await PhotoLibrary.checkAuthorization()
        guard authorized else {
            logger.error("Photo library access was not authorized.")
            return
        }
        
        Task {
            do {
                try await self.photoCollection.load()
                await self.loadThumbnail()
            } catch let error {
                logger.error("Failed to load photo collection: \(error.localizedDescription)")
            }
            self.isPhotosLoaded = true
        }
    }
    
    func loadThumbnail() async {
        guard let asset = photoCollection.photoAssets.first  else { return }
        await photoCollection.cache.requestImage(for: asset, targetSize: CGSize(width: 256, height: 256))  { result in
            if let result = result {
                Task { @MainActor in
                    self.thumbnailImage = result.image
                }
            }
        }
    }
}

fileprivate struct PhotoData {
    var thumbnailImage: Image
    var thumbnailSize: (width: Int, height: Int)
    var imageData: Data
    var imageSize: (width: Int, height: Int)
}

fileprivate extension CIImage {
    var image: Image? {
        let ciContext = CIContext()
        guard let cgImage = ciContext.createCGImage(self, from: self.extent) else { return nil }
        return Image(decorative: cgImage, scale: 1, orientation: .up)
    }
}

fileprivate extension Image.Orientation {

    init(_ cgImageOrientation: CGImagePropertyOrientation) {
        switch cgImageOrientation {
        case .up: self = .up
        case .upMirrored: self = .upMirrored
        case .down: self = .down
        case .downMirrored: self = .downMirrored
        case .left: self = .left
        case .leftMirrored: self = .leftMirrored
        case .right: self = .right
        case .rightMirrored: self = .rightMirrored
        }
    }
}

fileprivate let logger = Logger(subsystem: "com.apple.swiftplaygroundscontent.capturingphotos", category: "DataModel")

