import AVFoundation
import KSPlayer
import SwiftUI
import UIKit

@main
struct PocketBoxApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = AppStore()
    @StateObject private var playerManager = PlayerEngineManager.shared
    @StateObject private var sleepTimer = SleepTimerManager.shared
    @StateObject private var audioSession = AudioSessionManager.shared

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .environmentObject(playerManager)
                .environmentObject(sleepTimer)
                .environmentObject(audioSession)
                .onAppear {
                    playerManager.store = store
                    KSOptions.canBackgroundPlay = store.backgroundPlayEnabled
                    KSOptions.hardwareDecode = store.hardwareDecode
                    audioSession.configureAndActivate(audioOnlyMode: store.defaultAudioOnlyMode)
                    if !store.sources.filter(\.isEnabled).isEmpty && store.sources.allSatisfy({ $0.lastUpdated == nil }) {
                        Task { await store.syncAllEnabledSources() }
                    }
                }
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    static var orientationLock: UIInterfaceOrientationMask = UIDevice.current.userInterfaceIdiom == .pad ? .all : .portrait

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        KSOptions.canBackgroundPlay = true
        KSOptions.firstPlayerType = KSAVPlayer.self
        KSOptions.secondPlayerType = KSMEPlayer.self
        AudioSessionManager.shared.configureAndActivate()
        application.beginReceivingRemoteControlEvents()
        return true
    }

    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        AppDelegate.orientationLock
    }

    static func setOrientation(_ mask: UIInterfaceOrientationMask, rotateTo target: UIInterfaceOrientation? = nil) {
        orientationLock = mask
        if let target {
            UIDevice.current.setValue(target.rawValue, forKey: "orientation")
        }
        UIViewController.attemptRotationToDeviceOrientation()
    }
}
