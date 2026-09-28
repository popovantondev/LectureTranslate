#!/usr/bin/ruby
require "fileutils"
require "json"
require "digest"
require "open3"
require "tmpdir"
require_relative "release-validation"
Dir.chdir(File.expand_path("..", __dir__))
def run(*args)
  abort "Command failed: #{args.first}" unless system(*args)
end
version = File.read("VERSION").strip
abort "Invalid version" unless version.match?(/\A\d+\.\d+\.\d+\z/)
build = File.read("BUILD_NUMBER").strip
abort "Invalid build number" unless build.match?(/\A\d+\z/)
product_name = `/usr/libexec/PlistBuddy -c 'Print CFBundleName' Info.plist`.strip
abort "Invalid product name" unless product_name.match?(/\ALectureTranslate\z/)
tag = "v#{version}"
FileUtils.mkdir_p(".build")
lock = File.open(".build/release.lock", "w")
abort "Another release is running" unless lock.flock(File::LOCK_EX | File::LOCK_NB)
status, ok = Open3.capture2("git", "status", "--porcelain", "--untracked-files=normal")
abort "Commit source and docs first" unless ok.success? && status.empty?
abort "Release notes are missing" unless File.file?("docs/releases/#{tag}.md")
commit, ok = Open3.capture2("git", "rev-parse", "HEAD")
abort "Cannot resolve commit" unless ok.success?
commit = commit.strip
tag_commit, tag_status = Open3.capture2("git", "rev-parse", "--verify", "--quiet", "refs/tags/#{tag}^{commit}")
published = File.exist?("releases/#{tag}")
abort "Release already exists; unchanged" if published && tag_status.success?
abort "Tag belongs to another commit; unchanged" if tag_status.success? && tag_commit.strip != commit
# A crash after the final directory rename but before tagging is recoverable.
if published
  ReleaseValidation.verify_package!("releases/#{tag}", commit, version)
  run("git", "-c", "user.name=LectureTranslate Maintainers", "-c", "user.email=maintainers@lecturetranslate.invalid", "tag", "-a", tag, "-m", "LectureTranslate #{version} (build #{build})")
  puts "Recovered tag for #{tag}; release files unchanged."
  exit
end
run("bash", "Scripts/test-all.sh")
if File.exist?("dist/#{tag}")
  puts "Checking existing build for safe packaging resume (no rebuild)."
else
  run("bash", "Scripts/build.sh")
end
after, ok = Open3.capture2("git", "status", "--porcelain", "--untracked-files=normal")
head, = Open3.capture2("git", "rev-parse", "HEAD")
abort "Source changed during build; release not published" unless ok.success? && after.empty? && head.strip == commit
manifest = ReleaseValidation.verify_build!("dist/#{tag}", commit, version, File.read("BUILD_NUMBER").strip)
FileUtils.mkdir_p("releases")
stage = Dir.mktmpdir("release-", ".build")
app = "dist/#{tag}/#{product_name}.app"
abort "Built application is missing" unless File.directory?(app)
run("ditto", "-c", "-k", "--keepParent", app, "#{stage}/lecture_translate-#{tag}-app.zip")
run("git", "archive", "--format=zip", "--prefix=lecture_translate-#{tag}/", "-o", "#{stage}/lecture_translate-#{tag}-source.zip", commit)
Dir.glob("#{stage}/*.zip").each { |p| run("unzip", "-tq", p) }
FileUtils.cp("docs/releases/#{tag}.md", "#{stage}/RELEASE.md")
File.write("#{stage}/manifest.json", JSON.pretty_generate(manifest))
sums = Dir.children(stage).sort.map { |n| "#{Digest::SHA256.file("#{stage}/#{n}").hexdigest}  #{n}" }.join("\n") + "\n"
File.write("#{stage}/SHA256SUMS", sums)
after, ok = Open3.capture2("git", "status", "--porcelain", "--untracked-files=normal")
head, = Open3.capture2("git", "rev-parse", "HEAD")
abort "Source changed during packaging; rerun from clean state" unless ok.success? && after.empty? && head.strip == commit
File.rename(stage, "releases/#{tag}")
unless tag_status.success?
  run("git", "-c", "user.name=LectureTranslate Maintainers", "-c", "user.email=maintainers@lecturetranslate.invalid", "tag", "-a", tag, "-m", "LectureTranslate #{version} (build #{build})")
end
puts "Released #{tag}; old releases unchanged."
