import Flutter
import UIKit

class SceneDelegate: FlutterSceneDelegate {
  override func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    super.scene(scene, willConnectTo: session, options: connectionOptions)
    guard let windowScene = scene as? UIWindowScene,
      windowScene.traitCollection.userInterfaceIdiom == .pad
    else { return }
    // iPad runs the wide three-column shell, which needs at least this much
    // width. `UIRequiresFullScreen` is deprecated from iPadOS 26 and stops
    // opting out of window resizing on iPadOS 27 (TN3192), so pin the scene's
    // minimum size instead of relying on that key.
    windowScene.sizeRestrictions?.minimumSize = CGSize(width: 1000, height: 600)
  }
}
