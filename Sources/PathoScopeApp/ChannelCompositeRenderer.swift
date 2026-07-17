struct ChannelDisplaySettings: Identifiable, Equatable {
    let id: String
    let name: String
    var red: Double
    var green: Double
    var blue: Double
    var isVisible = true
    var brightness: Double = 0
    var contrast: Double = 1
    var black: Double = 0
    var white: Double = 0.5
    var gamma: Double = 1
}

struct ChannelLUTPreset: Identifiable, Equatable {
    let id: String
    let name: String
    let red: Double
    let green: Double
    let blue: Double

    static let all: [ChannelLUTPreset] = [
        ChannelLUTPreset(id: "blue", name: "蓝", red: 0, green: 0, blue: 1),
        ChannelLUTPreset(id: "red", name: "红", red: 1, green: 0, blue: 0),
        ChannelLUTPreset(id: "green", name: "绿", red: 0, green: 1, blue: 0),
        ChannelLUTPreset(id: "yellow", name: "黄", red: 1, green: 1, blue: 0),
        ChannelLUTPreset(id: "magenta", name: "品红", red: 1, green: 0, blue: 1),
        ChannelLUTPreset(id: "cyan", name: "青", red: 0, green: 1, blue: 1),
        ChannelLUTPreset(id: "white", name: "白", red: 1, green: 1, blue: 1)
    ]
}
