require "tmpdir"
require "fileutils"
require_relative "../Scripts/release-validation"

checks = 0
assert = lambda { |condition| raise "Assertion failed" unless condition; checks += 1 }
reject = lambda do |&operation|
  rejected = false
  begin
    operation.call
  rescue StandardError
    rejected = true
  end
  assert.call(rejected)
end

Dir.mktmpdir("lecture-release-tests-") do |root|
  Dir.chdir(root) do
    FileUtils.mkdir_p(%w[Sources Assets Resources/de.lproj Resources/ru.lproj Resources/en.lproj dist/v1.0.0])
    %w[de ru en].each { |locale| File.write("Resources/#{locale}.lproj/Localizable.strings", "\"test\" = \"#{locale}\";\n") }
    File.write("Sources/Test.swift", "// fixture\n")
    File.write("VERSION", "1.0.0\n")
    File.write("BUILD_NUMBER", "1\n")
    File.write("Info.plist", '<plist version="1.0"><dict><key>CFBundleName</key><string>LectureTranslate</string><key>CFBundleIdentifier</key><string>local.release.tests</string><key>CFBundleExecutable</key><string>LectureTranslator</string><key>CFBundlePackageType</key><string>APPL</string><key>CFBundleShortVersionString</key><string>1.0.0</string><key>CFBundleVersion</key><string>1</string><key>CFBundleDevelopmentRegion</key><string>de</string><key>CFBundleLocalizations</key><array><string>de</string><string>ru</string><string>en</string></array></dict></plist>')
    %w[icns png].each { |ext| File.write("Assets/TranslatorIcon.#{ext}", "fixture #{ext}") }
    folder = "dist/v1.0.0"
    app = "#{folder}/LectureTranslate.app"
    FileUtils.mkdir_p(["#{app}/Contents/MacOS", "#{app}/Contents/Resources"])
    FileUtils.cp("/usr/bin/true", "#{app}/Contents/MacOS/LectureTranslator")
    FileUtils.cp("Info.plist", "#{app}/Contents/Info.plist")
    FileUtils.cp(Dir.glob("Assets/*"), "#{app}/Contents/Resources")
    %w[de ru en].each { |locale| FileUtils.cp_r("Resources/#{locale}.lproj", "#{app}/Contents/Resources/") }
    raise "Fixture signing failed" unless system("/usr/bin/codesign", "--force", "--sign", "-", "--timestamp=none", app, err: File::NULL)
    raise "Git init failed" unless system("git", "init", "-q")
    system("git", "add", "Sources", "Assets", "Resources", "VERSION", "BUILD_NUMBER", "Info.plist") || raise("Git add failed")
    system("git", "-c", "user.name=Release Test", "-c", "user.email=test@localhost", "commit", "-qm", "fixture") || raise("Git commit failed")
    commit, = Open3.capture2("git", "rev-parse", "HEAD")
    commit = commit.strip
    manifest = {"version" => "1.0.0", "build" => "1", "product_name" => "LectureTranslate", "sources" => ReleaseValidation.source_paths.to_h { |path| [path, Digest::SHA256.file(path).hexdigest] }, "binary" => Digest::SHA256.file("#{app}/Contents/MacOS/LectureTranslator").hexdigest}
    missing_resource = "Resources/en.lproj/Localizable.strings"
    FileUtils.rm(missing_resource)
    reject.call { ReleaseValidation.source_paths }
    File.write(missing_resource, "\"test\" = \"en\";\n")
    save = -> { File.write("#{folder}/build-manifest.json", JSON.generate(manifest)) }
    save.call
    assert.call(ReleaseValidation.verify_build!(folder, commit, "1.0.0", "1")["commit"] == commit)
    reject.call { ReleaseValidation.verify_build!(folder, commit, "1.0.1", "1") }
    reject.call { ReleaseValidation.verify_build!(folder, commit, "1.0.0", "2") }
    File.write("Sources/Test.swift", "changed")
    reject.call { ReleaseValidation.verify_build!(folder, commit, "1.0.0", "1") }
    File.write("Sources/Test.swift", "// fixture\n")
    value = manifest["sources"].delete("VERSION"); save.call
    reject.call { ReleaseValidation.verify_build!(folder, commit, "1.0.0", "1") }
    manifest["sources"]["VERSION"] = value; save.call
    File.write("#{app}/Contents/Resources/TranslatorIcon.png", "changed")
    reject.call { ReleaseValidation.verify_build!(folder, commit, "1.0.0", "1") }
    FileUtils.cp("Assets/TranslatorIcon.png", "#{app}/Contents/Resources/TranslatorIcon.png")
    File.write("#{app}/Contents/Resources/de.lproj/Localizable.strings", "changed")
    reject.call { ReleaseValidation.verify_build!(folder, commit, "1.0.0", "1") }
    FileUtils.cp("Resources/de.lproj/Localizable.strings", "#{app}/Contents/Resources/de.lproj/Localizable.strings")
    original_binary = File.binread("#{app}/Contents/MacOS/LectureTranslator")
    File.open("#{app}/Contents/MacOS/LectureTranslator", "ab") { |f| f.write("changed") }
    reject.call { ReleaseValidation.verify_build!(folder, commit, "1.0.0", "1") }
    File.binwrite("#{app}/Contents/MacOS/LectureTranslator", original_binary)

    FileUtils.mkdir_p("release")
    %w[app source].each do |kind|
      system("/usr/bin/zip", "-q", "release/lecture_translate-v1.0.0-#{kind}.zip", "VERSION") || raise("ZIP failed")
    end
    File.write("release/RELEASE.md", "Test")
    File.write("release/manifest.json", JSON.generate(manifest.merge("commit" => commit)))
    sums = Dir.children("release").sort.map { |name| "#{Digest::SHA256.file("release/#{name}").hexdigest}  #{name}" }.join("\n") + "\n"
    File.write("release/SHA256SUMS", sums)
    assert.call(ReleaseValidation.verify_package!("release", commit, "1.0.0"))
    reject.call { ReleaseValidation.verify_package!("release", "wrong", "1.0.0") }
    reject.call { ReleaseValidation.verify_package!("release", commit, "1.0.1") }
    File.write("release/RELEASE.md", "changed")
    reject.call { ReleaseValidation.verify_package!("release", commit, "1.0.0") }
    File.write("release/RELEASE.md", "Test")
    File.write("release/SHA256SUMS", sums.lines.drop(1).join)
    reject.call { ReleaseValidation.verify_package!("release", commit, "1.0.0") }
  end
end
puts "PASS: #{checks} release validation checks. No model requests."
