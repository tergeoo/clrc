import UIKit

/// Screens that hide the navigation bar for their own header (chat,
/// terminal) still get the edge swipe back: UIKit turns the interactive pop
/// gesture off when the bar is hidden unless something answers its delegate.
extension UINavigationController: @retroactive UIGestureRecognizerDelegate {
    override open func viewDidLoad() {
        super.viewDidLoad()
        interactivePopGestureRecognizer?.delegate = self
    }

    public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        viewControllers.count > 1
    }
}
