class Piclight < Formula
  desc "Native macOS image viewer"
  homepage "https://github.com/realDGD/PicLight"
  head "https://github.com/realDGD/PicLight.git", branch: "main"

  depends_on :macos

  on_macos do
    depends_on macos: :sonoma
  end

  # SwiftPM invokes Apple's compiler directly; do not substitute Homebrew's CC shims.
  env :std

  def install
    ENV["DEVELOPER_DIR"] = "/Library/Developer/CommandLineTools"
    ENV.prepend_path "PATH", "#{ENV.fetch("DEVELOPER_DIR")}/usr/bin"
    sdk = Utils.safe_popen_read("/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-version").strip
    odie "PicLight needs Command Line Tools with macOS SDK 26 or newer" if Version.new(sdk) < Version.new("26.0")

    ENV["SDKROOT"] = Utils.safe_popen_read("/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-path").strip
    ENV["MACOSX_DEPLOYMENT_TARGET"] = "14.0"
    ENV["CLANG_MODULE_CACHE_PATH"] = (buildpath/".build/clang-module-cache").to_s
    ENV["SWIFTPM_MODULECACHE_OVERRIDE"] = (buildpath/".build/swift-module-cache").to_s
    ENV["PICLIGHT_SWIFTPM_DISABLE_SANDBOX"] = "1"
    system "/bin/bash", "scripts/build-release.sh"
    prefix.install "dist/PicLight.app"
  end

  def caveats
    <<~EOS
      Run the locally compiled app:
        open "#{opt_prefix}/PicLight.app"

      Optional Finder / Launchpad link (fails safely if the destination exists):
        mkdir -p "$HOME/Applications"
        ln -s "#{opt_prefix}/PicLight.app" "$HOME/Applications/PicLight.app"

      This build is ad-hoc signed locally and does not need a Developer ID certificate.
    EOS
  end

  test do
    app = prefix/"PicLight.app"
    assert_path_exists app/"Contents/Resources/Assets.car"
    assert_path_exists app/"Contents/Resources/PicViewMac_PicViewMac.bundle/Contents/Resources/default.metallib"
    system "/usr/bin/codesign", "--verify", "--deep", "--strict", app
    assert_match "Signature=adhoc",
                 shell_output("/usr/bin/codesign --display --verbose=2 #{app.to_s.shellescape} 2>&1")
    with_env("PICLIGHT_METAL_PROBE" => "1") do
      assert_match(/metal=(ok|unavailable)/, shell_output((app/"Contents/MacOS/PicLight").to_s.shellescape))
    end
  end
end
