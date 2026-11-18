import AppKit
import Security

enum UpdateInstaller {
    static func verifiedHelper(in bundle: Bundle = .main) throws -> URL {
        let url = bundle.bundleURL.appendingPathComponent("Contents/Helpers/NearClipUpdater.app")
        var own: SecCode?, ownStatic: SecStaticCode?, requirement: SecRequirement?, raw: CFString?
        guard SecCodeCopySelf([], &own) == errSecSuccess, let own,
              SecCodeCopyStaticCode(own, [], &ownStatic) == errSecSuccess, let ownStatic,
              SecCodeCopyDesignatedRequirement(ownStatic, [], &requirement) == errSecSuccess, let requirement,
              SecRequirementCopyString(requirement, [], &raw) == errSecSuccess, let raw else {
            throw ClipError.invalid(ui("Couldn’t verify the app signature."))
        }
        let text = raw as String
        guard text.contains("identifier \"dev.nearclip.mac\""), text.contains("certificate"), !text.contains("cdhash") else {
            throw ClipError.invalid(ui("Install the public release to use in-app updates."))
        }
        let helperText = text.replacingOccurrences(of: "identifier \"dev.nearclip.mac\"", with: "identifier \"dev.nearclip.updater\"")
        var expected: SecRequirement?, helper: SecStaticCode?
        guard SecRequirementCreateWithString(helperText as CFString, [], &expected) == errSecSuccess,
              SecStaticCodeCreateWithPath(url as CFURL, [], &helper) == errSecSuccess, let helper,
              SecStaticCodeCheckValidity(helper, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode), expected) == errSecSuccess else {
            throw ClipError.invalid(ui("Couldn’t verify the updater signature. Reinstall the official app."))
        }
        return url
    }
    static func open(completion: @escaping (Error?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try verifiedHelper() }
            DispatchQueue.main.async {
                switch result {
                case .failure(let error): completion(error)
                case .success(let url):
                    if let running = NSRunningApplication.runningApplications(withBundleIdentifier: "dev.nearclip.updater")
                        .first(where: { $0.bundleURL?.standardizedFileURL == url.standardizedFileURL }) {
                        running.activate(options: [.activateAllWindows]); completion(nil); return
                    }
                    let configuration = NSWorkspace.OpenConfiguration(); configuration.activates = true
                    configuration.createsNewApplicationInstance = true
                    configuration.arguments = ["-AppleLanguages", "(\(AppLanguage.current))"]
                    NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
                        DispatchQueue.main.async { completion(error) }
                    }
                }
            }
        }
    }
}
