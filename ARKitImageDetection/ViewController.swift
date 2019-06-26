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
    let db = Firestore.firestore()
    
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
        
        db.collection("3D-Models").getDocuments() { (querySnapshot, err) in
            if let err = err {
                print("Error getting documents: \(err)")
            } else {
                for document in querySnapshot!.documents {
                    print("\(document.documentID) => \(document.data())")
                }
            }
        }
        
    }

	override func viewDidAppear(_ animated: Bool) {
		super.viewDidAppear(animated)
		
		// Prevent the screen from being dimmed to avoid interuppting the AR experience.
		UIApplication.shared.isIdleTimerDisabled = true

        // Start the AR experience
        resetTracking()
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
        
        guard let referenceImages = ARReferenceImage.referenceImages(inGroupNamed: "AR Resources", bundle: nil) else {
            fatalError("Missing expected asset catalog resources.")
        }
        
        let configuration = ARWorldTrackingConfiguration()
        configuration.detectionImages = referenceImages
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
            if referenceImage.name == "iPad Pro 12.9-inch" {
                let sphere = SCNSphere(radius: 0.03)
                let material = SCNMaterial()
                material.diffuse.contents = UIColor.black
                sphere.materials = [material]
        
                self.addModel(fileName: "paperPlane.scn", position: planeNode.position, node: node)

            }
        }
        
        DispatchQueue.main.async {
            let imageName = referenceImage.name ?? ""
            self.statusViewController.cancelAllScheduledMessages()
            self.statusViewController.showMessage("Detected image “\(imageName)”")
        }
    }
    
    //issue with this function is that it adds the child to sceneView.scene.rootNode not node like in renderer
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

