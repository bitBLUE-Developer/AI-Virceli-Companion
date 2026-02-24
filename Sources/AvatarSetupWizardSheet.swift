import SwiftUI

struct AvatarSetupWizardSheet: View {
    @Environment(\.dismiss) private var dismiss

    @State private var mappings: [AvatarBoneMappingRow] = AvatarBoneMappingRow.defaultRows
    @State private var statusText: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Avatar Setup Wizard")
                .font(.headline)
            Text("Mixamo bone key -> Target skeleton bone name")
                .font(.caption)
                .foregroundStyle(.secondary)

            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach($mappings) { $row in
                        HStack(spacing: 8) {
                            Text(row.mixamoKey)
                                .font(.system(.caption, design: .monospaced))
                                .frame(width: 130, alignment: .leading)
                            Image(systemName: "arrow.right")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            TextField("Target bone name", text: $row.targetBoneName)
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(height: 420)

            if !statusText.isEmpty {
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("Load Profile") { loadProfile() }
                Button("Save Profile") { saveProfile() }
                Button("Reset Default") { mappings = AvatarBoneMappingRow.defaultRows }
                Spacer()
                Button("Close") { dismiss() }
            }
        }
        .padding(16)
        .frame(width: 640, height: 620)
        .onAppear { loadProfile() }
    }

    private func loadProfile() {
        guard let url = profileURL() else {
            statusText = "profile path not found"
            return
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            statusText = "no profile file yet: \(url.path)"
            return
        }
        do {
            let data = try Data(contentsOf: url)
            let profile = try JSONDecoder().decode(AvatarProfile.self, from: data)
            for idx in mappings.indices {
                if let value = profile.mixamoToTarget[mappings[idx].mixamoKey] {
                    mappings[idx].targetBoneName = value
                }
            }
            statusText = "loaded \(url.lastPathComponent)"
        } catch {
            statusText = "load failed: \(error.localizedDescription)"
        }
    }

    private func saveProfile() {
        guard let url = profileURL() else {
            statusText = "profile path not found"
            return
        }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let map = Dictionary(uniqueKeysWithValues: mappings.map { ($0.mixamoKey, $0.targetBoneName.trimmingCharacters(in: .whitespacesAndNewlines)) })
            let profile = AvatarProfile(version: 1, mixamoToTarget: map)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(profile)
            try data.write(to: url, options: .atomic)
            statusText = "saved: \(url.path)"
            NotificationCenter.default.post(name: .avatarProfileDidChange, object: nil)
        } catch {
            statusText = "save failed: \(error.localizedDescription)"
        }
    }

    private func profileURL() -> URL? {
        let fileManager = FileManager.default

        // 1) Preferred: the user's selected Claude workspace.
        if let savedWorkspace = UserDefaults.standard.string(forKey: "claude.workspace.path"), !savedWorkspace.isEmpty {
            let workspaceURL = URL(fileURLWithPath: savedWorkspace, isDirectory: true)
            let workspaceAssets = workspaceURL.appendingPathComponent("public/assets/avatars", isDirectory: true)
            if fileManager.fileExists(atPath: workspaceAssets.path) {
                return workspaceAssets.appendingPathComponent("avatar_profile.json")
            }
        }

        // 2) Fallback: current working directory (dev run).
        let cwd = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
        let candidates = [
            cwd.appendingPathComponent("public/assets/avatars", isDirectory: true),
            cwd.appendingPathComponent("native-macos/public/assets/avatars", isDirectory: true),
            cwd.deletingLastPathComponent().appendingPathComponent("public/assets/avatars", isDirectory: true),
            cwd.deletingLastPathComponent().appendingPathComponent("native-macos/public/assets/avatars", isDirectory: true)
        ]

        if let matched = candidates.first(where: { fileManager.fileExists(atPath: $0.path) }) {
            return matched.appendingPathComponent("avatar_profile.json")
        }
        return nil
    }
}

struct AvatarBoneMappingRow: Identifiable {
    let id = UUID()
    let mixamoKey: String
    var targetBoneName: String

    static let defaultRows: [AvatarBoneMappingRow] = [
        .init(mixamoKey: "Hips", targetBoneName: "J_Bip_C_Hips"),
        .init(mixamoKey: "Spine", targetBoneName: "J_Bip_C_Spine"),
        .init(mixamoKey: "Spine1", targetBoneName: "J_Bip_C_Chest"),
        .init(mixamoKey: "Spine2", targetBoneName: "J_Bip_C_UpperChest"),
        .init(mixamoKey: "Neck", targetBoneName: "J_Bip_C_Neck"),
        .init(mixamoKey: "Head", targetBoneName: "J_Bip_C_Head"),
        .init(mixamoKey: "LeftShoulder", targetBoneName: "J_Bip_L_Shoulder"),
        .init(mixamoKey: "LeftArm", targetBoneName: "J_Bip_L_UpperArm"),
        .init(mixamoKey: "LeftForeArm", targetBoneName: "J_Bip_L_LowerArm"),
        .init(mixamoKey: "LeftHand", targetBoneName: "J_Bip_L_Hand"),
        .init(mixamoKey: "RightShoulder", targetBoneName: "J_Bip_R_Shoulder"),
        .init(mixamoKey: "RightArm", targetBoneName: "J_Bip_R_UpperArm"),
        .init(mixamoKey: "RightForeArm", targetBoneName: "J_Bip_R_LowerArm"),
        .init(mixamoKey: "RightHand", targetBoneName: "J_Bip_R_Hand"),
        .init(mixamoKey: "LeftUpLeg", targetBoneName: "J_Bip_L_UpperLeg"),
        .init(mixamoKey: "LeftLeg", targetBoneName: "J_Bip_L_LowerLeg"),
        .init(mixamoKey: "LeftFoot", targetBoneName: "J_Bip_L_Foot"),
        .init(mixamoKey: "LeftToeBase", targetBoneName: "J_Bip_L_ToeBase"),
        .init(mixamoKey: "RightUpLeg", targetBoneName: "J_Bip_R_UpperLeg"),
        .init(mixamoKey: "RightLeg", targetBoneName: "J_Bip_R_LowerLeg"),
        .init(mixamoKey: "RightFoot", targetBoneName: "J_Bip_R_Foot"),
        .init(mixamoKey: "RightToeBase", targetBoneName: "J_Bip_R_ToeBase")
    ]
}

struct AvatarProfile: Codable {
    let version: Int
    let mixamoToTarget: [String: String]
}
