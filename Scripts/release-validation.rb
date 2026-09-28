require "json"
require "digest"
require "open3"
require "rexml/document"

# Read-only guards. Never replace a build or trust only its version number.
module ReleaseValidation
  def self.plist_values(path)
    dict = REXML::Document.new(File.read(path)).elements["plist/dict"]
    children = dict.elements.to_a
    children.each_slice(2).to_h { |key, value| [key.text, value] }
  end

  def self.source_paths
    locales = %w[de ru en].map { |locale| "Resources/#{locale}.lproj/Localizable.strings" }
    raise "Missing localization source" unless locales.all? { |path| File.file?(path) && File.size?(path) }
    (Dir.glob("Sources/*.swift") + %w[Info.plist VERSION BUILD_NUMBER Assets/TranslatorIcon.icns Assets/TranslatorIcon.png] + locales).sort
  end

  def self.verify_build!(folder, commit, version, build)
    manifest = JSON.parse(File.read(File.join(folder, "build-manifest.json")))
    raise "Wrong build version" unless manifest.fetch("version") == version && manifest.fetch("build") == build
    raise "Missing build inputs" unless manifest.fetch("sources").keys.sort == source_paths
    manifest.fetch("sources").each do |path, hash|
      data, status = Open3.capture2("git", "show", "#{commit}:#{path}")
      raise "Build/source mismatch: #{path}" unless status.success? && Digest::SHA256.hexdigest(data) == hash && Digest::SHA256.file(path).hexdigest == hash
    end
    product_name = manifest.fetch("product_name")
    raise "Wrong product name" unless product_name == "LectureTranslate"
    app = File.join(folder, "#{product_name}.app")
    info = plist_values("#{app}/Contents/Info.plist")
    raise "Bundle version/build mismatch" unless info.fetch("CFBundleShortVersionString").text == version && info.fetch("CFBundleVersion").text == build
    raise "Bundle product mismatch" unless info.fetch("CFBundleName").text == product_name && info.fetch("CFBundleDevelopmentRegion").text == "de"
    raise "Bundle localization declaration mismatch" unless info.fetch("CFBundleLocalizations").elements.to_a.map(&:text) == %w[de ru en]
    raise "Binary changed" unless Digest::SHA256.file("#{app}/Contents/MacOS/LectureTranslator").hexdigest == manifest.fetch("binary")
    bundled_resources = {"Info.plist" => "Info.plist", "Assets/TranslatorIcon.icns" => "Resources/TranslatorIcon.icns", "Assets/TranslatorIcon.png" => "Resources/TranslatorIcon.png"}
    %w[de ru en].each { |locale| bundled_resources["Resources/#{locale}.lproj/Localizable.strings"] = "Resources/#{locale}.lproj/Localizable.strings" }
    bundled_resources.each do |source, bundled|
      raise "Bundled resource changed: #{source}" unless Digest::SHA256.file("#{app}/Contents/#{bundled}").hexdigest == manifest.fetch("sources").fetch(source)
    end
    raise "Signature invalid" unless system("/usr/bin/codesign", "--verify", "--deep", "--strict", app)
    manifest.merge("commit" => commit)
  end

  def self.verify_package!(folder, commit, version)
    manifest = JSON.parse(File.read(File.join(folder, "manifest.json")))
    raise "Release commit/version mismatch" unless manifest.fetch("commit") == commit && manifest.fetch("version") == version
    expected = ["RELEASE.md", "manifest.json", "lecture_translate-v#{version}-app.zip", "lecture_translate-v#{version}-source.zip"].sort
    entries = File.readlines(File.join(folder, "SHA256SUMS"), chomp: true).map { |line| line.split("  ", 2) }
    raise "Incomplete checksums" unless entries.map(&:last).sort == expected
    entries.each do |hash, name|
      raise "Invalid checksum" unless hash.match?(/\A[0-9a-f]{64}\z/) && File.basename(name) == name
      raise "Package changed: #{name}" unless Digest::SHA256.file(File.join(folder, name)).hexdigest == hash
    end
    expected.grep(/\.zip\z/).each do |name|
      raise "Broken ZIP" unless system("/usr/bin/unzip", "-tq", File.join(folder, name), out: File::NULL)
    end
    true
  end
end
