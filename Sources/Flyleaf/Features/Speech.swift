import AVFoundation

// Say It: hover a name, hear it. Phonetic respellings from the pack speak
// better than the raw spelling for names like Zhengzhou or Luxshare.
@MainActor
enum Speech {
    private static let synthesizer = AVSpeechSynthesizer()

    static func say(_ text: String) {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = 0.45
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        synthesizer.speak(utterance)
    }
}
