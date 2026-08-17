//
//  Item.swift
//  Astronomy
//
//  Created by Shubhi Srivastava on 8/17/26.
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
