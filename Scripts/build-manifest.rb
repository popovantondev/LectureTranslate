require "json"
require "digest"
require "rexml/document"
stage, version, build = ARGV
abort "Usage: build-manifest.rb STAGE VERSION BUILD" unless stage && version && build
locales = %w[de ru en]
resources = locales.map { |locale| "Resources/#{locale}.lproj/Localizable.strings" }
abort "Missing or empty localization resource" unless resources.all? { |path| File.file?(path) && File.size?(path) }
files = Dir.glob("Sources/*.swift") + %w[Info.plist VERSION BUILD_NUMBER Assets/TranslatorIcon.icns Assets/TranslatorIcon.png] + resources
info = REXML::Document.new(File.read("Info.plist"))
product_name = info.elements["plist/dict/key[.='CFBundleName']"].next_element.text
app = File.join(stage, "#{product_name}.app")
resources.each do |path|
  bundled = File.join(app, "Contents/Resources", path.delete_prefix("Resources/"))
  abort "Missing bundled localization resource: #{path}" unless File.file?(bundled) && Digest::SHA256.file(path).hexdigest == Digest::SHA256.file(bundled).hexdigest
end
manifest = {version: version, build: build, product_name: product_name, sources: files.sort.to_h { |p| [p, Digest::SHA256.file(p).hexdigest] },
  binary: Digest::SHA256.file(File.join(app, "Contents/MacOS/LectureTranslator")).hexdigest}
File.open(File.join(stage, "build-manifest.json"), File::WRONLY | File::CREAT | File::EXCL) { |f| f.write(JSON.pretty_generate(manifest)) }
