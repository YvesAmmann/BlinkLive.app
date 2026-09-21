import SwiftUI
import UIKit

enum BlinkTheme {
    static let fuchsia = Color(light: 0xD41478, dark: 0xFF4FA3)
    static let cyan = Color(light: 0x008C9E, dark: 0x36D9E8)
    static let blue = Color(light: 0x185ADB, dark: 0x5C8DFF)

    static let background = Color(light: 0xF4F7FA, dark: 0x090C12)
    static let surface = Color(light: 0xFFFFFF, dark: 0x141923)
    static let secondarySurface = Color(light: 0xEDF2F7, dark: 0x202735)
    static let border = Color(light: 0xD7DEE8, dark: 0x343D4D)
    static let primaryText = Color(light: 0x151923, dark: 0xF3F6FA)
}

private extension Color {
    init(light: UInt32, dark: UInt32) {
        self.init(uiColor: UIColor { traits in
            UIColor(hex: traits.userInterfaceStyle == .dark ? dark : light)
        })
    }
}

private extension UIColor {
    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}