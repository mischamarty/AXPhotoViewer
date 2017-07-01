//
//  PhotosTransitionController.swift
//  Pods
//
//  Created by Alex Hill on 6/4/17.
//
//

import UIKit
import FLAnimatedImage

@objc(AXPhotosTransitionControllerMode) enum PhotosTransitionControllerMode: Int {
    case presenting, dismissing
}

@objc (AXPhotosTransitionController) class PhotosTransitionController: NSObject, UIViewControllerAnimatedTransitioning,
                                                                       UIViewControllerInteractiveTransitioning,
                                                                       UIGestureRecognizerDelegate {
    
    fileprivate let FadeInOutTransitionRatio: Double = 1/3
    
    weak var delegate: PhotosTransitionControllerDelegate?
    var mode: PhotosTransitionControllerMode = .presenting
    var transitionInfo: TransitionInfo
    
    weak var photosViewController: PhotosViewController?
    
    fileprivate var presentationOrientation: UIInterfaceOrientation
    fileprivate var dismissalOrientation: UIInterfaceOrientation
    
    /// The threshold at which the interactive controller will dismiss upon end touches.
    fileprivate var DismissalPercentThreshold: CGFloat = 0.14
    
    /// Pending animations that can occur when interactive dismissal has not been triggered by the system, 
    /// but our pan gesture recognizer is receiving touch events. Processed as soon as the interactive dismissal has been set up.
    fileprivate var pendingAnimations = [() -> Void]()
    
    // Interactive dismissal transition tracking
    fileprivate var dismissalPercent: CGFloat = 0
    fileprivate var directionalDismissalPercent: CGFloat = 0
    fileprivate var dismissalVelocityY: CGFloat = 1
    fileprivate var forceImmediateInteractiveDismissal = false
    fileprivate var completeInteractiveDismissal = false
    
    weak var dismissalTransitionContext: UIViewControllerContextTransitioning?
    
    weak fileprivate var imageView: UIImageView?
    fileprivate var imageViewInitialOriginY: CGFloat = .greatestFiniteMagnitude
    fileprivate var imageViewOriginalFrame: CGRect = .zero
    fileprivate var imageViewOriginalSuperview: UIView?
    
    weak fileprivate var overlayView: OverlayView?
    fileprivate var navigationBarInitialOriginY: CGFloat = .greatestFiniteMagnitude
    fileprivate var navigationBarUnderlayInitialOriginY: CGFloat = .greatestFiniteMagnitude
    fileprivate var captionViewInitialOriginY: CGFloat = .greatestFiniteMagnitude
    fileprivate var overlayViewOriginalFrame: CGRect = .zero
    fileprivate var overlayViewOriginalSuperview: UIView?
    
    var supportsContextualPresentation: Bool {
        get {
            return (self.transitionInfo.startingView != nil)
        }
    }
    
    var supportsContextualDismissal: Bool {
        get {
            return (self.transitionInfo.endingView != nil)
        }
    }
    
    var supportsInteractiveDismissal: Bool {
        get {
            return self.transitionInfo.interactiveDismissalEnabled
        }
    }
    
    init(photosViewController: PhotosViewController, transitionInfo: TransitionInfo) {
        self.photosViewController = photosViewController
        self.transitionInfo = transitionInfo
        
        let statusBarOrientation = UIApplication.shared.statusBarOrientation
        self.presentationOrientation = statusBarOrientation
        self.dismissalOrientation = statusBarOrientation
        
        super.init()
        
        if transitionInfo.interactiveDismissalEnabled {
            let panGestureRecognizer = UIPanGestureRecognizer(target: self, action: #selector(panAction(_:)))
            panGestureRecognizer.maximumNumberOfTouches = 1
            panGestureRecognizer.delegate = self
            photosViewController.view.addGestureRecognizer(panGestureRecognizer)
        }
        
        NotificationCenter.default.addObserver(forName: .UIApplicationDidChangeStatusBarOrientation,
                                               object: nil,
                                               queue: nil) { [weak self] (note) in
            guard let uSelf = self else {
                return
            }
                                                
            let statusBarOrientation = UIApplication.shared.statusBarOrientation
                                                
            if !photosViewController.isBeingPresented && !photosViewController.isBeingDismissed && photosViewController.presentingViewController == nil {
                uSelf.presentationOrientation = statusBarOrientation
            }
            
            if !photosViewController.isBeingDismissed && photosViewController.presentingViewController != nil {
                uSelf.dismissalOrientation = statusBarOrientation
            }
        }
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    // MARK: - UIViewControllerAnimatedTransitioning
    func transitionDuration(using transitionContext: UIViewControllerContextTransitioning?) -> TimeInterval {
        return self.transitionInfo.duration
    }
    
    func animateTransition(using transitionContext: UIViewControllerContextTransitioning) {
        if self.mode == .presenting {
            self.animatePresentation(using: transitionContext)
        } else if self.mode == .dismissing {
            self.animateDismissal(using: transitionContext)
        }
    }
    
    fileprivate func animatePresentation(using transitionContext: UIViewControllerContextTransitioning) {
        guard let to = transitionContext.viewController(forKey: .to) as? PhotosViewController,
            let from = transitionContext.viewController(forKey: .from),
            let referenceView = self.transitionInfo.startingView,
            let referenceViewCopy = self.transitionInfo.startingView?.copy() as? UIImageView else {
                assertionFailure("No. ಠ_ಠ")
                return
        }
        
        to.view.alpha = 0
        to.view.frame = transitionContext.finalFrame(for: to)
        transitionContext.containerView.addSubview(to.view)
        
        transitionContext.containerView.layoutIfNeeded()
        
        let referenceViewFrame = referenceView.frame
        referenceView.transform = .identity
        referenceView.frame = referenceViewFrame
        
        let referenceViewCenter = referenceView.center
        referenceViewCopy.transform = from.view.transform
        referenceViewCopy.center = transitionContext.containerView.convert(referenceViewCenter, from: referenceView.superview)
        transitionContext.containerView.addSubview(referenceViewCopy)
        
        referenceView.alpha = 0

        var imageAspectRatio: CGFloat = 1
        if let image = referenceViewCopy.image {
            imageAspectRatio = image.size.width / image.size.height
        }
        
        let referenceViewAspectRatio = referenceViewCopy.bounds.size.width / referenceViewCopy.bounds.size.height
        var aspectRatioAdjustedSize = referenceViewCopy.bounds.size
        if abs(referenceViewAspectRatio - imageAspectRatio) > .ulpOfOne {
            aspectRatioAdjustedSize.width = aspectRatioAdjustedSize.height * imageAspectRatio
        }
        
        let scale = min(to.view.frame.size.width / aspectRatioAdjustedSize.width, to.view.frame.size.height / aspectRatioAdjustedSize.height)
        let scaledSize = CGSize(width: aspectRatioAdjustedSize.width * scale, height: aspectRatioAdjustedSize.height * scale)
        let scaleAnimations = { () in
            referenceViewCopy.transform = .identity
            referenceViewCopy.frame.size = scaledSize
            referenceViewCopy.center = to.view.center
        }
        
        let scaleCompletion = { [weak self] (_ finished: Bool) in
            guard let uSelf = self else {
                return
            }
            
            uSelf.delegate?.transitionController(uSelf, didFinishAnimatingWith: referenceViewCopy, transitionControllerMode: .presenting)
            
            to.view.alpha = 1
            from.view.alpha = 1
            referenceView.alpha = 1
            referenceViewCopy.removeFromSuperview()
            transitionContext.completeTransition(true)
        }
        
        let fadeAnimations = {
            from.view.alpha = 0
        }
        
        UIView.animate(withDuration: self.transitionDuration(using: transitionContext),
                       delay: 0,
                       usingSpringWithDamping: 0.8,
                       initialSpringVelocity: 0,
                       options: [.curveEaseInOut, .beginFromCurrentState, .allowAnimatedContent],
                       animations: scaleAnimations,
                       completion: scaleCompletion)
        
        UIView.animate(withDuration: self.transitionDuration(using: transitionContext) * FadeInOutTransitionRatio,
                       delay: 0,
                       options: [.curveEaseInOut],
                       animations: fadeAnimations)
        
        UIView.animateCornerRadii(withDuration: self.transitionDuration(using: transitionContext) * FadeInOutTransitionRatio,
                                  to: 0,
                                  views: [referenceViewCopy])
    }
    
    fileprivate func animateDismissal(using transitionContext: UIViewControllerContextTransitioning) {
        guard let to = transitionContext.viewController(forKey: .to),
            let from = transitionContext.viewController(forKey: .from) as? PhotosViewController,
            let imageView = from.currentPhotoViewController?.zoomingImageView.imageView as UIImageView? else {
                assertionFailure("No. ಠ_ಠ")
                return
        }
        
        if to.view.superview != transitionContext.containerView || from.view.superview != transitionContext.containerView {
            to.view.alpha = 0
            to.view.frame = transitionContext.finalFrame(for: to)
            transitionContext.containerView.addSubview(to.view)
            
            from.view.frame = transitionContext.finalFrame(for: from)
            transitionContext.containerView.addSubview(from.view)
        }
        
        transitionContext.containerView.layoutIfNeeded()
        
        let imageViewFrame = imageView.frame
        imageView.transform = .identity
        imageView.frame = imageViewFrame
        
        if imageView.superview != transitionContext.containerView {
            let imageViewCenter = imageView.center
            imageView.transform = from.view.transform
            imageView.center = transitionContext.containerView.convert(imageViewCenter, from: imageView.superview)
            transitionContext.containerView.addSubview(imageView)
        }
        
        if self.canPerformContextualDismissal() {
            guard let referenceView = self.transitionInfo.endingView else {
                assertionFailure("No. ಠ_ಠ")
                return
            }
            
            imageView.contentMode = referenceView.contentMode
            referenceView.alpha = 0
        }
        
        from.overlayView.isHidden = true
        
        var offscreenImageViewCenter: CGPoint?
        let scaleAnimations = { [weak self] () in
            guard let uSelf = self else {
                return
            }
            
            if uSelf.canPerformContextualDismissal() {
                guard let referenceView = uSelf.transitionInfo.endingView else {
                    assertionFailure("No. ಠ_ಠ")
                    return
                }
                
                imageView.transform = .identity
                imageView.frame = transitionContext.containerView.convert(referenceView.frame, from: referenceView.superview)
            } else {
                guard let uOffscreenImageViewCenter = offscreenImageViewCenter else {
                    assertionFailure("No. ಠ_ಠ")
                    return
                }
                
                imageView.center = uOffscreenImageViewCenter
            }
        }
        
        let scaleCompletion = { [weak self] (_ finished: Bool) in
            guard let uSelf = self else {
                return
            }
            
            uSelf.delegate?.transitionController(uSelf, didFinishAnimatingWith: imageView, transitionControllerMode: .dismissing)
            
            if uSelf.canPerformContextualDismissal() {
                guard let referenceView = uSelf.transitionInfo.endingView else {
                    assertionFailure("No. ಠ_ಠ")
                    return
                }
                
                if let imageView = imageView as? FLAnimatedImageView, let referenceView = referenceView as? FLAnimatedImageView {
                    referenceView.ax_syncFrames(with: imageView)
                }
                
                referenceView.alpha = 1
            }
            
            imageView.removeFromSuperview()
            
            if transitionContext.isInteractive {
                transitionContext.finishInteractiveTransition()
            }
            
            transitionContext.completeTransition(true)
        }
        
        let fadeAnimations = {
            to.view.alpha = 1
            from.view.alpha = 0
        }
        
        var scaleAnimationOptions: UIViewAnimationOptions
        var scaleInitialSpringVelocity: CGFloat
        
        if self.canPerformContextualDismissal() {
            scaleAnimationOptions = [.curveEaseInOut, .beginFromCurrentState, .allowAnimatedContent]
            scaleInitialSpringVelocity = 0
        } else {
            let dismissBottom = (self.directionalDismissalPercent >= 0)
            let statusBarOrientation = UIApplication.shared.statusBarOrientation
            let tuple = self.computeOffscreenCenter(for: imageView,
                                                    in: transitionContext.containerView, 
                                                    startingOrientation: self.dismissalOrientation, 
                                                    endingOrientation: statusBarOrientation, 
                                                    dismissBottom: dismissBottom)
            
            offscreenImageViewCenter = tuple.center
            
            if self.forceImmediateInteractiveDismissal {
                scaleAnimationOptions = [.curveEaseInOut, .beginFromCurrentState, .allowAnimatedContent]
                scaleInitialSpringVelocity = 0
            } else {
                var divisor: CGFloat = 1
                let changed = tuple.changed
                if .ulpOfOne >= abs(changed - tuple.center.x) {
                    divisor = abs(changed - imageView.frame.origin.x)
                } else {
                    divisor = abs(changed - imageView.frame.origin.y)
                }
                
                scaleAnimationOptions = [.curveLinear, .beginFromCurrentState, .allowAnimatedContent]
                scaleInitialSpringVelocity = abs(self.dismissalVelocityY / divisor)
            }
        }

        UIView.animate(withDuration: self.transitionDuration(using: transitionContext),
                       delay: 0,
                       usingSpringWithDamping: 1.0,
                       initialSpringVelocity: scaleInitialSpringVelocity,
                       options: scaleAnimationOptions,
                       animations: scaleAnimations,
                       completion: scaleCompletion)
        
        UIView.animate(withDuration: self.transitionDuration(using: transitionContext) * FadeInOutTransitionRatio,
                       delay: 0,
                       options: [.curveEaseInOut],
                       animations: fadeAnimations)
        
        if self.canPerformContextualDismissal() {
            guard let referenceView = self.transitionInfo.endingView else {
                assertionFailure("No. ಠ_ಠ")
                return
            }
            
            UIView.animateCornerRadii(withDuration: self.transitionDuration(using: transitionContext) * FadeInOutTransitionRatio,
                                      to: referenceView.layer.cornerRadius,
                                      views: [imageView])
        }
    }
    
    fileprivate func cancelTransition(using transitionContext: UIViewControllerContextTransitioning) {
        guard let to = transitionContext.viewController(forKey: .to),
            let from = transitionContext.viewController(forKey: .from) as? PhotosViewController,
            let imageView = from.currentPhotoViewController?.zoomingImageView.imageView as UIImageView? else {
                assertionFailure("No. ಠ_ಠ")
                return
        }
        
        let overlayView = from.overlayView
        let animations = { [weak self] () in
            guard let uSelf = self else {
                return
            }
            
            imageView.frame.origin.y = uSelf.imageViewInitialOriginY
            overlayView.navigationBar.frame.origin.y = uSelf.navigationBarInitialOriginY
            overlayView.navigationBarUnderlay.frame.origin.y = uSelf.navigationBarUnderlayInitialOriginY
            (overlayView.captionView as? UIView)?.frame.origin.y = uSelf.captionViewInitialOriginY
            
            to.view.alpha = 0
        }
        
        let completion = { [weak self] (_ finished: Bool) in
            guard let uSelf = self else {
                return
            }

            if uSelf.canPerformContextualDismissal() {
                guard let referenceView = uSelf.transitionInfo.endingView else {
                    assertionFailure("No. ಠ_ಠ")
                    return
                }
                
                referenceView.alpha = 1
            }
            
            to.view.alpha = 1
            from.view.alpha = 1
            
            imageView.frame = transitionContext.containerView.convert(imageView.frame, to: uSelf.imageViewOriginalSuperview)
            uSelf.imageViewOriginalSuperview?.addSubview(imageView)
            overlayView.frame = transitionContext.containerView.convert(overlayView.frame, to: uSelf.overlayViewOriginalSuperview)
            uSelf.overlayViewOriginalSuperview?.addSubview(overlayView)
            
            if transitionContext.isInteractive {
                transitionContext.cancelInteractiveTransition()
            }
            
            transitionContext.completeTransition(false)
            uSelf.dismissalTransitionContext = nil
        }
        
        UIView.animate(withDuration: (1 - Double(self.dismissalPercent)) * self.transitionDuration(using: transitionContext),
                       delay: 0,
                       usingSpringWithDamping: 1.0,
                       initialSpringVelocity: 0,
                       options: [.curveEaseInOut, .beginFromCurrentState, .allowAnimatedContent],
                       animations: animations,
                       completion: completion)
    }
    
    // MARK: - UIViewControllerInteractiveTransitioning
    func startInteractiveTransition(_ transitionContext: UIViewControllerContextTransitioning) {
        self.dismissalTransitionContext = transitionContext
        
        guard let to = transitionContext.viewController(forKey: .to),
            let from = transitionContext.viewController(forKey: .from) as? PhotosViewController,
            let imageView = from.currentPhotoViewController?.zoomingImageView.imageView as UIImageView? else {
                assertionFailure("No. ಠ_ಠ")
                return
        }
        
        self.imageView = imageView
        self.overlayView = from.overlayView
        
        // if we're going to force an immediate dismissal, we can just return here
        // this setup will be done in `animateDismissal(_:)`
        guard !self.forceImmediateInteractiveDismissal else {
            self.processPendingAnimations()
            return
        }
        
        to.view.alpha = 0
        to.view.frame = transitionContext.finalFrame(for: to)
        transitionContext.containerView.addSubview(to.view)
        
        from.view.frame = transitionContext.finalFrame(for: from)
        transitionContext.containerView.addSubview(from.view)
        
        transitionContext.containerView.layoutIfNeeded()
        
        self.imageViewOriginalFrame = imageView.frame
        self.imageViewOriginalSuperview = imageView.superview
        imageView.center = transitionContext.containerView.convert(imageView.center, from: imageView.superview)
        transitionContext.containerView.addSubview(imageView)
        self.imageViewInitialOriginY = imageView.frame.origin.y
        
        let overlayView = from.overlayView
        self.overlayViewOriginalFrame = overlayView.frame
        self.overlayViewOriginalSuperview = overlayView.superview
        overlayView.frame = transitionContext.containerView.convert(overlayView.frame, from: overlayView.superview)
        transitionContext.containerView.addSubview(overlayView)
        
        self.navigationBarInitialOriginY = overlayView.navigationBar.frame.origin.y
        self.navigationBarUnderlayInitialOriginY = overlayView.navigationBarUnderlay.frame.origin.y
        self.captionViewInitialOriginY = (overlayView.captionView as? UIView)?.frame.origin.y ?? 0
        
        from.view.alpha = 0
        
        if self.canPerformContextualDismissal() {
            guard let referenceView = self.transitionInfo.endingView else {
                assertionFailure("No. ಠ_ಠ")
                return
            }
            
            referenceView.alpha = 0
        }
        
        self.processPendingAnimations()
    }
    
    // MARK: - Interaction handling
    @objc fileprivate func panAction(_ sender: UIPanGestureRecognizer) {
        self.dismissalVelocityY = sender.velocity(in: sender.view).y
        let translation = sender.translation(in: sender.view?.superview)
        
        switch sender.state {
        case .began:
            self.overlayView = nil
            self.photosViewController?.presentingViewController?.dismiss(animated: true, completion: {
                sender.isEnabled = true
            })
            
            let shouldForceImmediateInteractiveDismissal = (UIApplication.shared.statusBarOrientation != self.dismissalOrientation)
            if shouldForceImmediateInteractiveDismissal {
                // arbitrary dismissal percentages
                self.directionalDismissalPercent = self.dismissalVelocityY > 0 ? 1 : -1
                self.dismissalPercent = 1
                self.forceImmediateInteractiveDismissal = true
                self.completeInteractiveDismissal = true
                
                // immediately trigger `cancelled` for dismissal
                sender.isEnabled = false
            }
        case .changed:
            let animation = { [weak self] in
                guard let uSelf = self,
                    let transitionContext = uSelf.dismissalTransitionContext,
                    let to = transitionContext.viewController(forKey: .to),
                    let navigationBar = uSelf.overlayView?.navigationBar,
                    let navigationBarUnderlay = uSelf.overlayView?.navigationBarUnderlay,
                    let captionView = uSelf.overlayView?.captionView as? UIView else {
                        assertionFailure("No. ಠ_ಠ")
                        return
                }
                
                let height = UIScreen.main.bounds.size.height
                uSelf.directionalDismissalPercent = translation.y > 0 ? min(1, translation.y / height) : max(-1, translation.y / height)
                uSelf.dismissalPercent = min(1, abs(translation.y / height))
                uSelf.completeInteractiveDismissal = (uSelf.dismissalPercent >= uSelf.DismissalPercentThreshold)
                
                // this feels right-ish
                let dismissalRatio = (1.5 * uSelf.dismissalPercent / uSelf.DismissalPercentThreshold)
                
                let navigationBarOriginY = max(uSelf.navigationBarInitialOriginY - navigationBarUnderlay.frame.size.height,
                                               uSelf.navigationBarInitialOriginY - (navigationBarUnderlay.frame.size.height * dismissalRatio))
                let navigationBarUnderlayOriginY = max(uSelf.navigationBarUnderlayInitialOriginY - navigationBarUnderlay.frame.size.height,
                                                       uSelf.navigationBarUnderlayInitialOriginY - (navigationBarUnderlay.frame.size.height * dismissalRatio))
                let captionViewOriginY = min(uSelf.captionViewInitialOriginY + captionView.frame.size.height,
                                             uSelf.captionViewInitialOriginY + (captionView.frame.size.height * dismissalRatio))
                let imageViewOriginY = uSelf.imageViewInitialOriginY + translation.y
                
                UIView.performWithoutAnimation {
                    navigationBar.frame.origin.y = navigationBarOriginY
                    navigationBarUnderlay.frame.origin.y = navigationBarUnderlayOriginY
                    captionView.frame.origin.y = captionViewOriginY
                    uSelf.imageView?.frame.origin.y = imageViewOriginY
                }
                
                to.view.alpha = 1 * min(1, dismissalRatio)
            }
            
            guard self.overlayView != nil else {
                self.pendingAnimations.append(animation)
                return
            }
            
            animation()
            
        case .ended:
            fallthrough
        case .cancelled:
            let animation = { [weak self] in
                guard let uSelf = self,
                    let transitionContext = uSelf.dismissalTransitionContext,
                    let _ = uSelf.overlayView?.navigationBar,
                    let _ = uSelf.overlayView?.navigationBarUnderlay,
                    let _ = uSelf.overlayView?.captionView as? UIView else {
                        return
                }
                
                if uSelf.completeInteractiveDismissal {
                    uSelf.animateDismissal(using: transitionContext)
                } else {
                    uSelf.cancelTransition(using: transitionContext)
                }
            }
            
            // `overlayView` is set in `startInteractiveTransition(_:)`
            guard self.overlayView != nil else {
                self.pendingAnimations.append(animation)
                return
            }
            
            animation()
            
        default:
            break
        }
    }
    
    // MARK: - Helpers
    fileprivate func processPendingAnimations() {
        for animation in self.pendingAnimations {
            animation()
        }
        
        self.pendingAnimations.removeAll()
    }
    
    fileprivate func canPerformContextualDismissal() -> Bool {
        guard let endingView = self.transitionInfo.endingView, let endingViewSuperview = endingView.superview else {
            return false
        }
        
        return UIScreen.main.bounds.intersects(endingViewSuperview.convert(endingView.frame, to: nil))
    }
    
    // come back to this later, maybe
    
    /// Retrieve the "final" offscreen center value for an image view in a view given the starting and ending orientations.
    ///
    /// - Parameters:
    ///   - imageView: The image view to retrieve the final offscreen center value for.
    ///   - view: The view that is containing the imageView. Most likely the superview.
    ///   - startingOrientation: The starting orientation for the image view. This can be the same as the endingOrientation.
    ///   - endingOrientation: The ending orientation for the image view. This can be the same as the startingOrientation.
    ///   - dismissBottom: Whether or not the center value should dismiss to the bottom of the view or not. If not, the center value
    ///                    will be calculated to dismiss at the top of the view.
    /// - Returns: A tuple containing the final center of the imageView, as well as the value that was adjusted from the original `center` value.
    fileprivate func computeOffscreenCenter(for imageView: UIImageView,
                                            in view: UIView, startingOrientation: UIInterfaceOrientation,
                                            endingOrientation: UIInterfaceOrientation,
                                            dismissBottom: Bool) -> (center: CGPoint, changed: CGFloat) {
        
        let imageViewRect = imageView.convert(imageView.bounds, to: view)
        var imageViewCenter = imageView.center
        
        switch startingOrientation {
        case .landscapeLeft:
            switch endingOrientation {
            case .landscapeLeft:
                if dismissBottom {
                    imageViewCenter.y = view.frame.size.height + (imageViewRect.size.height / 2)
                } else {
                    imageViewCenter.y = -(imageViewRect.size.height / 2)
                }
            case .landscapeRight:
                if dismissBottom {
                    imageViewCenter.y = -(imageViewRect.size.height / 2)
                } else {
                    imageViewCenter.y = view.frame.size.height + (imageViewRect.size.height / 2)
                }
            case .portraitUpsideDown:
                if dismissBottom {
                    imageViewCenter.x = -(imageViewRect.size.width / 2)
                } else {
                    imageViewCenter.x = view.frame.size.width + (imageViewRect.size.width / 2)
                }
            default:
                if dismissBottom {
                    imageViewCenter.x = view.frame.size.width + (imageViewRect.size.width / 2)
                } else {
                    imageViewCenter.x = -(imageViewRect.size.width / 2)
                }
            }
        case .landscapeRight:
            switch endingOrientation {
            case .landscapeLeft:
                if dismissBottom {
                    imageViewCenter.y = -(imageViewRect.size.height / 2)
                } else {
                    imageViewCenter.y = view.frame.size.height + (imageViewRect.size.height / 2)
                }
            case .landscapeRight:
                if dismissBottom {
                    imageViewCenter.y = view.frame.size.height + (imageViewRect.size.height / 2)
                } else {
                    imageViewCenter.y = -(imageViewRect.size.height / 2)
                }
            case .portraitUpsideDown:
                if dismissBottom {
                    imageViewCenter.x = view.frame.size.width + (imageViewRect.size.width / 2)
                } else {
                    imageViewCenter.x = -(imageViewRect.size.width / 2)
                }
            default:
                if dismissBottom {
                    imageViewCenter.x = -(imageViewRect.size.width / 2)
                } else {
                    imageViewCenter.x = view.frame.size.width + (imageViewRect.size.width / 2)
                }
            }
        case .portraitUpsideDown:
            switch endingOrientation {
            case .landscapeLeft:
                if dismissBottom {
                    imageViewCenter.x = view.frame.size.width + (imageViewRect.size.width / 2)
                } else {
                    imageViewCenter.x = -(imageViewRect.size.width / 2)
                }
            case .landscapeRight:
                if dismissBottom {
                    imageViewCenter.x = -(imageViewRect.size.width / 2)
                } else {
                    imageViewCenter.x = view.frame.size.width + (imageViewRect.size.width / 2)
                }
            case .portraitUpsideDown:
                if dismissBottom {
                    imageViewCenter.y = view.frame.size.height + (imageViewRect.size.height / 2)
                } else {
                    imageViewCenter.y = -(imageViewRect.size.height / 2)
                }
            default:
                if dismissBottom {
                    imageViewCenter.y = -(imageViewRect.size.height / 2)
                } else {
                    imageViewCenter.y = view.frame.size.height + (imageViewRect.size.height / 2)
                }
            }
        default:
            switch endingOrientation {
            case .landscapeLeft:
                if dismissBottom {
                    imageViewCenter.x = -(imageViewRect.size.width / 2)
                } else {
                    imageViewCenter.x = view.frame.size.width + (imageViewRect.size.width / 2)
                }
            case .landscapeRight:
                if dismissBottom {
                    imageViewCenter.x = view.frame.size.width + (imageViewRect.size.width / 2)
                } else {
                    imageViewCenter.x = -(imageViewRect.size.width / 2)
                }
            case .portraitUpsideDown:
                if dismissBottom {
                    imageViewCenter.y = -(imageViewRect.size.height / 2)
                } else {
                    imageViewCenter.y = view.frame.size.height + (imageViewRect.size.height / 2)
                }
            default:
                if dismissBottom {
                    imageViewCenter.y = view.frame.size.height + (imageViewRect.size.height / 2)
                } else {
                    imageViewCenter.y = -(imageViewRect.size.height / 2)
                }
            }
        }
        
        if abs(imageView.center.x - imageViewCenter.x) >= .ulpOfOne {
            return (imageViewCenter, imageViewCenter.x)
        } else {
            return (imageViewCenter, imageViewCenter.y)
        }
    }
    
    // MARK: - UIGestureRecognizerDelegate
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let photosViewController = self.photosViewController else {
            return false
        }
        
        let currentPhotoIndex = photosViewController.currentPhotoIndex
        let dataSource = photosViewController.dataSource
        let zoomingImageView = photosViewController.currentPhotoViewController?.zoomingImageView
        let pagingConfig = photosViewController.pagingConfig
        
        guard !(zoomingImageView?.isScrollEnabled ?? true) &&
            (pagingConfig.navigationOrientation == .horizontal ||
            (pagingConfig.navigationOrientation == .vertical &&
            (currentPhotoIndex == 0 || currentPhotoIndex == dataSource.numberOfPhotos - 1))) else {
            return false
        }
        
        if let panGestureRecognizer = gestureRecognizer as? UIPanGestureRecognizer {
            let velocity = panGestureRecognizer.velocity(in: gestureRecognizer.view)
            
            let isVertical = abs(velocity.y) > abs(velocity.x)
            guard isVertical else {
                return false
            }
            
            if pagingConfig.navigationOrientation == .horizontal {
                return isVertical
            } else {
                if currentPhotoIndex == 0 {
                    return velocity.y > 0
                } else {
                    return velocity.y < 0
                }
            }
        }
        
        return true
    }
    
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        return true
    }
    
}

@objc(AXPhotosTransitionControllerDelegate) protocol PhotosTransitionControllerDelegate {
    
    @objc(transitionController:didFinishAnimatingWithView:animatorMode:)
    func transitionController(_ transitionController: PhotosTransitionController,
                              didFinishAnimatingWith view: UIImageView,
                              transitionControllerMode: PhotosTransitionControllerMode)
    
}
