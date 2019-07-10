//
//  ViewController.swift
//  graffito
//
//  Created by Alex Ionkov on 6/17/19.
//  Copyright © 2019 Alex Ionkov. All rights reserved.

import ARKit
import SceneKit
import UIKit
import SceneKit.ModelIO
import FirebaseStorage
import FirebaseFirestore

class ViewController: UIViewController, ARSCNViewDelegate {
    
    let storage = Storage.storage();
    let db = Firestore.firestore();
    var referenceImageNames: [String] = [];
    var downloadModelNames: [String] = [];
    
    var dictionary: [String: String] = [:];
    
    @IBOutlet var sceneView: ARSCNView!
    
    @IBOutlet weak var blurView: UIVisualEffectView!
    
    /// The view controller that displays the status and "restart experience" UI.
    lazy var statusViewController: StatusViewController = {
        return children.lazy.compactMap({ $0 as? StatusViewController }).first!
    }()
    
    /// A serial queue for thread safety when modifying the SceneKit node graph.
    let updateQueue = DispatchQueue(label: Bundle.main.bundleIdentifier! +
        ".serialSceneKitQueue")
    
    /// Convenience accessor for the session owned by ARSCNView.
    var session: ARSession {
        return sceneView.session
    }
    
    @objc func click(sender: UIButton) {
        let screenshot = self.sceneView.snapshot()
        UIImageWriteToSavedPhotosAlbum(screenshot, nil, nil, nil);
        
        if let wnd = self.view{
            
            var v = UIView(frame: wnd.bounds)
            v.backgroundColor = UIColor.white
            v.alpha = 1
            
            wnd.addSubview(v)
            UIView.animate(withDuration: 1, animations: {
                v.alpha = 0.0
            }, completion: {(finished:Bool) in
                v.removeFromSuperview()
            })
        }
    }
    // MARK: - View Controller Life Cycle
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        sceneView.delegate = self
        sceneView.session.delegate = self
        sceneView.showsStatistics = true
        //antialiasing
        sceneView.antialiasingMode = .multisampling4X

        // Hook up status view controller callback(s).
        statusViewController.restartExperienceHandler = { [unowned self] in
            self.restartExperience()
        }
        
        let settings = db.settings;
        settings.areTimestampsInSnapshotsEnabled = true;
        db.settings = settings;
        
        
        //setup taking pictures
        let snapBtn = UIButton();
        snapBtn.setTitle("Add", for: .normal)
        snapBtn.setImage(UIImage(named: "snap2.png"), for: .normal)
        snapBtn.frame = CGRect(x: UIScreen.main.bounds.width/2, y: 6*UIScreen.main.bounds.height/7, width: 100, height: 100)
        snapBtn.center = CGPoint(x: UIScreen.main.bounds.width/2, y: 6*UIScreen.main.bounds.height/7)
        self.view.addSubview(snapBtn)
        snapBtn.addTarget(self, action: #selector(click), for: .touchUpInside)
        
        
        //uploadModel(pathToFile: "paperPlane.scn", fileName: "paperPlane.scn")
        //uploadRefrenceImage(pathToFile: "paperPlane.scn", fileName: "paperPlane.scn")
        
    }

	override func viewDidAppear(_ animated: Bool) {
		super.viewDidAppear(animated)
		
		// Prevent the screen from being dimmed to avoid interuppting the AR experience.
		UIApplication.shared.isIdleTimerDisabled = true

        // Start the AR experience
        //resetTracking()
        
        downloadReferenceImages();

	}
	
	override func viewWillDisappear(_ animated: Bool) {
		super.viewWillDisappear(animated)

        session.pause()
	}

    // MARK: - Session management (Image detection setup)
    
    /// Prevents restarting the session while a restart is in progress.
    var isRestartAvailable = true

    /// Creates a new AR configuration to run on the `session`.
    /// - Tag: ARReferenceImage-Loading
	func resetTracking() {
        
        let configuration = ARWorldTrackingConfiguration()
        session.run(configuration, options: [.resetTracking, .removeExistingAnchors])

        statusViewController.scheduleMessage("Look around to detect images", inSeconds: 7.5, messageType: .contentPlacement)
	}
    
    // MARK: - ARSCNViewDelegate (Image detection results)
    /// - Tag: ARImageAnchor-Visualizing
    func renderer(_ renderer: SCNSceneRenderer, didAdd node: SCNNode, for anchor: ARAnchor) {
        guard let imageAnchor = anchor as? ARImageAnchor else { return }
        let referenceImage = imageAnchor.referenceImage
        updateQueue.async {
            
            // Create a plane to visualize the initial position of the detected image.
            let plane = SCNPlane(width: referenceImage.physicalSize.width,
                                 height: referenceImage.physicalSize.height)
            let planeNode = SCNNode(geometry: plane)
            planeNode.opacity = 0.25
            
            /*
             `SCNPlane` is vertically oriented in its local coordinate space, but
             `ARImageAnchor` assumes the image is horizontal in its local space, so
             rotate the plane to match.
             */
            planeNode.eulerAngles.x = -.pi / 2
            
            /*
             Image anchors are not tracked after initial detection, so create an
             animation that limits the duration for which the plane visualization appears.
             */
            planeNode.runAction(self.imageHighlightAction)
            
            // Add the plane visualization to the scene.
            node.addChildNode(planeNode)
            
            //sphere
            if self.referenceImageNames.contains(referenceImage.name!){
                let sphere = SCNSphere(radius: 0.03)
                let material = SCNMaterial()
                material.diffuse.contents = UIColor.black
                sphere.materials = [material]
                
                print("model selected: " + self.dictionary[referenceImage.name!]!)
                
                self.addModel(fileName: self.dictionary[referenceImage.name!]!, position: planeNode.position, node: node)
            }
        }
        
        DispatchQueue.main.async {
            let imageName = referenceImage.name ?? ""
            self.statusViewController.cancelAllScheduledMessages()
            self.statusViewController.showMessage("Detected image “\(imageName)”")
        }
    }
    
    func addModel(fileName: String, position: SCNVector3, node: SCNNode) {
        
        let storageRef = self.storage.reference();
        let Model = storageRef.child("3D-Model/" + fileName);
        
        // Create local filesystem URL
        let paths = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true)[0] as String
        let tempDirectory = URL.init(fileURLWithPath: paths, isDirectory: true)
        let targetUrl = tempDirectory.appendingPathComponent(fileName)
        Model.write(toFile: targetUrl) { (url, error) in
            if error != nil {
                print("ERROR: \(error!)")
            }else{
                print("modelPath.write OKAY")
            }
        }
            // load the 3D-Model node from directory path
            guard let modelScene = try? SCNScene(url: targetUrl, options: nil) else { return }
            
            let modelNode = SCNNode()
            let modelSceneChildNodes = modelScene.rootNode.childNodes
            
            for childNode in modelSceneChildNodes {
                modelNode.addChildNode(childNode)
            }
            
            modelNode.position = position //z-0.2
            modelNode.scale = SCNVector3(0.2, 0.2, 0.2)
            node.addChildNode(modelNode)
        
    }
    
    var imageHighlightAction: SCNAction {
        return .sequence([
            .wait(duration: 0.25),
            .fadeOpacity(to: 0.85, duration: 0.25),
            .fadeOpacity(to: 0.15, duration: 0.25),
            .fadeOpacity(to: 0.85, duration: 0.25),
            .fadeOut(duration: 0.5),
            .removeFromParentNode()
            ])
    }
    
    func merge(){
        self.dictionary = Dictionary(uniqueKeysWithValues: zip(referenceImageNames, downloadModelNames))
        print(dictionary);
    }
    
    func downloadModels(){
        let group = DispatchGroup() // initialize
        session.pause()

        db.collection("3D-Models").getDocuments() { (querySnapshot, err) in
            if let err = err {
                print("Error getting documents: \(err)")
            } else {
                group.enter() // wait

                for document in querySnapshot!.documents {
                    let fileName = document.documentID
                    print(fileName)
                    self.downloadModelNames.append(fileName.trimmingCharacters(in: .whitespacesAndNewlines));
                    
                    let storageRef = self.storage.reference();
                    
                    let Model = storageRef.child("3D-Model/" + fileName);
                    
                    // Create local filesystem URL
                    let paths = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true)[0] as String
                    let tempDirectory = URL.init(fileURLWithPath: paths, isDirectory: true)
                    let targetUrl = tempDirectory.appendingPathComponent(fileName)
                    Model.write(toFile: targetUrl) { (url, error) in
                        if error != nil {
                            print("ERROR: \(error!)")
                        }else{
                            print("model " + fileName + " downloaded")
                        }
                    }
                }
                group.leave() // continue the loop
            }
        }
        group.notify(queue: .main) {
            // do something here when loop finished
            self.resetTracking()
            
        }
    }
    
    func downloadReferenceImages(){
        
        let group = DispatchGroup() // initialize
        session.pause()
        var customReferenceSet = Set<ARReferenceImage>()
        
        print("starting download........")
        db.collection("ReferenceImages").getDocuments() { (querySnapshot, err) in
            if let err = err {
                print("Error getting documents: \(err)")
            } else {
                let configuration = ARWorldTrackingConfiguration()
                print("starting refrence image download........")
                let maingroup = DispatchGroup()
                for document in querySnapshot!.documents {
                    maingroup.enter()
                    
                    let fileName = document.documentID

                    let storageRef = self.storage.reference();
                    
                    let Model = storageRef.child("ReferenceImages/" + fileName);
                    
                    // Create local filesystem URL
                    let paths = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true)[0] as String
                    let tempDirectory = URL.init(fileURLWithPath: paths, isDirectory: true)
                    let targetUrl = tempDirectory.appendingPathComponent(fileName)
                    Model.write(toFile: targetUrl) { (url, error) in
                        if error != nil {
                            print("ERROR: \(error!)")
                        }else{
                            print(url)
                            self.referenceImageNames.append(fileName.trimmingCharacters(in: .whitespacesAndNewlines));
                            
                            //5. Name The Image
                            
                            let imageData = try! Data(contentsOf: url!)
                            
                            let image = UIImage(data: imageData)
                            
                            let arImage = ARReferenceImage(image!.cgImage!,
                                                       orientation: CGImagePropertyOrientation.up,
                                                       physicalWidth: 0.038)
                            arImage.name = fileName
                            
                            customReferenceSet.insert(arImage)
                            
                            print("reference image " + fileName + " downloaded")
                            print(self.dictionary);
                            maingroup.leave()
                            
                        }
                    }
                }
                for document in querySnapshot!.documents {
                    maingroup.notify(queue: .main, execute: {
                        print("starting model download........")
                        group.enter() // wait
                        
                        let storageRef = self.storage.reference();
                        
                        let docData = document.data();
                        
                        let modelName = docData["3D-Model"] as? String ?? ""
                        
                        let modelPath = storageRef.child("3D-Model/" + modelName);
                        
                        // Create local filesystem URL
                        let newPaths = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true)[0] as String
                        let newTempDirectory = URL.init(fileURLWithPath: newPaths, isDirectory: true)
                        let newTargetUrl = newTempDirectory.appendingPathComponent("3D_models/" + modelName)
                        modelPath.write(toFile: newTargetUrl) { (url, error) in
                            if error != nil {
                                print("ERROR: \(error!)")
                            }else{
                                self.downloadModelNames.append(modelName.trimmingCharacters(in: .whitespacesAndNewlines));
                                print("model " + modelName + " downloaded")
                                group.leave() // continue the loop
                                
                            }
                        }
                    })
                }
                
                group.notify(queue: .main) {
                    print("Finished all requests.")
                    print(customReferenceSet)
                    
                    configuration.detectionImages = customReferenceSet
                    
                    self.session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
                    self.statusViewController.scheduleMessage("Look around to detect images", inSeconds: 7.5, messageType: .contentPlacement)
                    
                    self.merge()
                }
            }
        }
    }
    
    func uploadReferenceImage(pathToFile: String, fileName: String){
        
        let storageRef = self.storage.reference();
        
        // Create a reference to the file you want to upload
        let riversRef = storageRef.child("ReferenceImages/" + fileName)
        
        let paths = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true)[0] as String
        let tempDirectory = URL.init(fileURLWithPath: paths, isDirectory: true)
        let targetUrl = tempDirectory.appendingPathComponent(fileName)
        
        // Upload the file to the path "images/rivers.jpg"
        _ = riversRef.putFile(from: targetUrl,  metadata: nil) { metadata, error in
            guard metadata != nil else {
                // Uh-oh, an error occurred!
                print("did not upload file")
                return
            }
                print("upload Success!!")
        }
        
        // Add a new document with a generated ID
        db.collection("ReferenceImages").document(fileName).setData(["":""]) { err in
            if let err = err {
                print("Error adding document: \(err)")
            } else {
                print("Document added")
            }
        }
        
        
    }
    
    func uploadModel(pathToFile: String, fileName: String){
        
        /*let paths = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true)[0] as String
        let tempDirectory = URL.init(fileURLWithPath: paths, isDirectory: true)
        let localFile = tempDirectory.appendingPathComponent(fileName)*/
        
        let storageRef = self.storage.reference();
        
        // Create a reference to the file you want to upload
        let riversRef = storageRef.child("3D-Model/" + fileName)
        
        let paths = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true)[0] as String
        let tempDirectory = URL.init(fileURLWithPath: paths, isDirectory: true)
        let targetUrl = tempDirectory.appendingPathComponent(fileName)
        
        // Upload the file to the path "images/rivers.jpg"
        _ = riversRef.putFile(from: targetUrl, metadata: nil) { metadata, error in
            guard metadata != nil else {
                // Uh-oh, an error occurred!
                print("did not upload file")
                return
            }
            print("upload Success!!")
        }
        
        // Add a new document with a generated ID
        db.collection("3D-Models").document(fileName).setData(["":""])  { err in
            if let err = err {
                print("Error adding document: \(err)")
            } else {
                print("Document added")
            }
        }
        
    }
    
    func convertCIImageToCGImage(inputImage: CIImage) -> CGImage? {
        let context = CIContext(options: nil)
        if let cgImage = context.createCGImage(inputImage, from: inputImage.extent) {
            return cgImage
        }
        return nil
    }
}

extension SCNNode {
    
    convenience init(named name: String) {
        self.init()
        
        guard let scene = SCNScene(named: name) else {
            return
        }
        
        for childNode in scene.rootNode.childNodes {
            addChildNode(childNode)
        }
    }
    
}

