import AudioToolbox
import Foundation
import PasteMeCore

/// 复制被记录时播放 PasteMe 自己的提示音（`RecordChime`，#25），4 个版本轮流。
///
/// 用系统音效服务（`AudioServicesPlaySystemSoundWithCompletion`）播放：它的 `kAudioServicesPropertyIsUISound`
/// 默认为 1，用户在系统设置里关掉「播放用户界面音效」时不出声，界面提示音应该这样。系统音效服务只能播放文件，
/// 所以每次启动后第一次播放时合成、写进 `~/Library/Caches/PasteMe/RecordSound-<n>.wav`、载入：不拖慢启动，
/// 改了声音下次启动就生效。
@MainActor
final class SystemRecordSound: RecordSoundPlaying {
    private var takes: [SystemSoundID]?
    private var rotation = TakeRotation()

    func play() {
        let takes = takes ?? load()
        guard !takes.isEmpty else { return }
        AudioServicesPlaySystemSoundWithCompletion(takes[rotation.next(count: takes.count)], nil)
    }

    /// 载入失败时记下空数组，不再重试。
    private func load() -> [SystemSoundID] {
        var ids: [SystemSoundID] = []
        do {
            let caches = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let folder = caches.appendingPathComponent("PasteMe", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for (index, data) in RecordChime.takes().enumerated() {
                let file = folder.appendingPathComponent("RecordSound-\(index + 1).wav")
                try data.write(to: file, options: .atomic)
                var id: SystemSoundID = 0
                let status = AudioServicesCreateSystemSoundID(file as CFURL, &id)
                guard status == kAudioServicesNoError else {
                    throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
                }
                ids.append(id)
            }
        } catch {
            NSLog("PasteMe: 无法准备提示音：\(error)")
            ids = []
        }
        takes = ids
        return ids
    }
}
