//
//  RemoteWidgetBundle.swift
//  RemoteWidget
//
//  Created by kairi hoshino on 2026/01/08.
//

import WidgetKit
import SwiftUI

@main
struct RemoteWidgetBundle: WidgetBundle {
    var body: some Widget {
        RemoteWidget()
        RemoteWidgetControl()
    }
}
