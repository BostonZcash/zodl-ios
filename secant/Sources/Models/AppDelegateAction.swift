//
//  AppDelegateAction.swift
//  Zashi
//
//  Created by Lukáš Korba on 27.03.2022.
//

import Foundation
import BackgroundTasks

enum AppDelegateAction: Equatable {
    case didFinishLaunching
    case didEnterBackground
    case willEnterForeground
    case backgroundTask(BGProcessingTask)
    /// PHASE 4: a migration notification was tapped. `accountUUID` is the hex-encoded account the
    /// notification was COMPOSED for, so a tap opens that account's run rather than whichever one
    /// happens to be selected now; `nil` falls back to the selected account. `isTorFailure` routes
    /// to the failure sheet instead of the flow (its own surface arrives with Phase 5).
    case migrationNotificationTapped(accountUUID: String?, isTorFailure: Bool)
}
