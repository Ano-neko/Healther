import PhotosUI
import SwiftUI

struct Composer: View {
    @Environment(AppModel.self) private var model
    @Binding var text: String
    @Binding var photos: [UIImage]
    var focused: FocusState<Bool>.Binding
    var onSend: () -> Void

    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var showCamera = false
    @State private var showLibrary = false

    var canSend: Bool { !model.isResponding && (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !photos.isEmpty) }

    var body: some View {
        VStack(spacing: 8) {
            if !photos.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(photos.indices, id: \.self) { i in
                            Image(uiImage: photos[i])
                                .resizable().scaledToFill()
                                .frame(width: 64, height: 64)
                                .clipShape(.rect(cornerRadius: 14))
                                .overlay(alignment: .topTrailing) {
                                    Button { photos.remove(at: i) } label: {
                                        Image(systemName: "xmark.circle.fill").symbolRenderingMode(.palette)
                                            .foregroundStyle(.white, .black.opacity(0.6))
                                    }
                                    .offset(x: 5, y: -5)
                                }
                        }
                    }
                    .padding(.horizontal, 4)
                    .padding(.top, 6)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            GlassEffectContainer(spacing: 10) {
                HStack(alignment: .bottom, spacing: 10) {
                    Menu {
                        if UIImagePickerController.isSourceTypeAvailable(.camera) {
                            Button { showCamera = true } label: { Label("拍照", systemImage: "camera") }
                        }
                        Button { showLibrary = true } label: { Label("从相册选择", systemImage: "photo.on.rectangle") }
                    } label: {
                        Image(systemName: "camera.fill")
                            .font(.system(size: 17, weight: .semibold))
                            .frame(width: 44, height: 44)
                    }
                    .glassEffect(.regular.interactive(), in: .circle)

                    TextField("说点什么…", text: $text, axis: .vertical)
                        .lineLimit(1...5)
                        .focused(focused)
                        .font(.system(size: 16))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .glassEffect(.regular, in: .rect(cornerRadius: 22))
                        .submitLabel(.send)

                    Button(action: onSend) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 17, weight: .bold))
                            .frame(width: 44, height: 44)
                    }
                    .disabled(!canSend)
                    .glassEffect(canSend ? .regular.tint(Theme.blue.opacity(0.75)).interactive() : .regular, in: .circle)
                    .animation(.snappy, value: canSend)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
        .animation(.snappy, value: photos.count)
        .onChange(of: pickerItems) { _, items in
            Task {
                for item in items {
                    if let data = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: data) {
                        photos.append(img)
                    }
                }
                pickerItems = []
            }
        }
        .photosPicker(isPresented: $showLibrary, selection: $pickerItems, maxSelectionCount: 4, matching: .images)
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { img in if let img { photos.append(img) } }
                .ignoresSafeArea()
        }
    }
}

/// UIKit camera wrapper (SwiftUI has no camera capture view).
struct CameraPicker: UIViewControllerRepresentable {
    var onPick: (UIImage?) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let c = UIImagePickerController()
        c.sourceType = .camera
        c.delegate = context.coordinator
        return c
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor
    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            parent.onPick(info[.originalImage] as? UIImage)
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.onPick(nil)
            parent.dismiss()
        }
    }
}
