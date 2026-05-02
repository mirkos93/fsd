#
# fsd.podspec — vendored xcframework consumer.
#
# The xcframework is produced by `tool/build_ios_xcframework.sh` (run on a
# Mac) and is NOT committed. If it's missing, `pod install` aborts with a
# clear message instead of silently producing a broken pod.
#
# Run `pod lib lint ios/fsd.podspec` to validate.
#

xcframework_path = File.expand_path('Frameworks/fsd.xcframework', __dir__)

unless File.directory?(xcframework_path)
  raise <<~MSG

    fsd: ios/Frameworks/fsd.xcframework not found.

    Build it first on a Mac with Xcode:
        ./tool/build_ios_xcframework.sh

    Then re-run `pod install`.

  MSG
end

Pod::Spec.new do |s|
  s.name             = 'fsd'
  s.version          = '0.0.1'
  s.summary          = 'On-device image generation via stable-diffusion.cpp.'
  s.description      = <<-DESC
    Flutter FFI plugin wrapping leejet/stable-diffusion.cpp. The native code
    is shipped as a prebuilt xcframework; see tool/build_ios_xcframework.sh
    in the plugin repo for how to (re)produce it.
  DESC
  s.homepage         = 'https://github.com/Tacita-app/fsd'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Tacita' => 'mirkos93@gmail.com' }

  s.source           = { :path => '.' }
  s.vendored_frameworks = 'Frameworks/fsd.xcframework'

  s.dependency 'Flutter'
  s.platform = :ios, '13.0'

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386',
    # Keep Objective-C categories alive (ggml's Metal shim uses them).
    'OTHER_LDFLAGS' => '$(inherited) -ObjC',
  }
  s.swift_version = '5.0'
end
