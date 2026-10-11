//
//  Item.swift
//  ayeneh
//
//  Created by Sonny Vesali on 10/11/26.
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
