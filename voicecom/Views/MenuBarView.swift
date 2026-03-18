import SwiftUI

struct MenuBarView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 0) {
            // Main content
            VStack(spacing: 16) {
                // Mic button area
                micButton

                // Status
                statusBadge

                // Last transcription
                if !appState.lastTranscription.isEmpty {
                    transcriptionCard
                }

                // Error
                if let error = appState.errorMessage {
                    errorBanner(error)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 12)

            Divider()

            // Footer
            footer
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
        }
        .frame(width: 280)
    }

    // MARK: - Mic Button

    @ViewBuilder
    private var micButton: some View {
        Button {
            Task { await appState.toggleRecording() }
        } label: {
            ZStack {
                // Outer pulsing ring when recording
                if appState.isRecording {
                    PulsingRing()
                }

                // Background circle
                Circle()
                    .fill(micButtonColor.gradient)
                    .frame(width: 64, height: 64)
                    .shadow(color: micButtonColor.opacity(0.4), radius: appState.isRecording ? 12 : 0)

                // Icon
                if appState.isTranscribing {
                    ProgressView()
                        .controlSize(.regular)
                        .tint(.white)
                } else {
                    Image(systemName: appState.isRecording ? "stop.fill" : "mic.fill")
                        .font(.system(size: 24, weight: .medium))
                        .foregroundStyle(.white)
                        .contentTransition(.symbolEffect(.replace))
                }
            }
            .animation(.easeInOut(duration: 0.3), value: appState.isRecording)
        }
        .buttonStyle(.plain)
        .disabled(!appState.isModelLoaded || appState.isTranscribing)
        .opacity(appState.isModelLoaded ? 1.0 : 0.5)
    }

    private var micButtonColor: Color {
        if appState.isRecording {
            return .red
        } else if appState.isTranscribing {
            return .orange
        } else {
            return .accentColor
        }
    }

    // MARK: - Status Badge

    @ViewBuilder
    private var statusBadge: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusDotColor)
                .frame(width: 7, height: 7)

            Text(appState.statusMessage)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(.quaternary, in: Capsule())
    }

    private var statusDotColor: Color {
        if appState.isRecording {
            return .red
        } else if appState.isTranscribing {
            return .orange
        } else if appState.isModelLoaded {
            return .green
        } else {
            return .gray
        }
    }

    // MARK: - Transcription Card

    @ViewBuilder
    private var transcriptionCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Last transcription")
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                Spacer()

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(appState.lastTranscription, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Copy to clipboard")
            }

            Text(appState.lastTranscription)
                .font(.callout)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .padding(10)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Error Banner

    @ViewBuilder
    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
                .font(.caption)

            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Footer

    @ViewBuilder
    private var footer: some View {
        HStack {
            // Model info
            modelChip

            Spacer()

            // Settings button
            Button {
                NSApp.activate()
                openSettings()
                DispatchQueue.main.async {
                    for window in NSApp.windows where window.identifier?.rawValue == "com_apple_SwiftUI_Settings_window" {
                        window.level = .floating
                    }
                }
            } label: {
                Image(systemName: "gear")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(",", modifiers: .command)

            // Quit button
            Button {
                Task {
                    await appState.shutdown()
                    NSApplication.shared.terminate(nil)
                }
            } label: {
                Image(systemName: "power")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut("q", modifiers: .command)
        }
    }

    @ViewBuilder
    private var modelChip: some View {
        if appState.isModelLoading {
            HStack(spacing: 4) {
                ProgressView()
                    .controlSize(.mini)
                Text(appState.isModelDownloading ? "Downloading…" : "Loading…")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        } else if appState.isModelLoaded {
            Text(appState.selectedModel)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        } else {
            Text("Model not loaded")
                .font(.caption2)
                .foregroundStyle(.red.opacity(0.8))
        }
    }
}

// MARK: - Pulsing Ring Animation

struct PulsingRing: View {
    @State private var isAnimating = false

    var body: some View {
        Circle()
            .stroke(Color.red.opacity(0.3), lineWidth: 3)
            .frame(width: 80, height: 80)
            .scaleEffect(isAnimating ? 1.15 : 1.0)
            .opacity(isAnimating ? 0.0 : 0.6)
            .animation(
                .easeOut(duration: 1.2).repeatForever(autoreverses: false),
                value: isAnimating
            )
            .onAppear { isAnimating = true }
    }
}
