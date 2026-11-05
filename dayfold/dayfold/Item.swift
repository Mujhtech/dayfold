//
//  Item.swift
//  dayfold
//
//  Created by Muhideen Mujeeb on 05/11/2026.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
