#!/usr/bin/ruby
require "digest"
require "fileutils"
require "json"
require "open3"
require "optparse"
require "tmpdir"
require "zlib"

module PublicExport
  class Error < StandardError; end

  def self.run(source:, allowlist:, output:)
    source = File.realpath(source)
    allowlist = File.expand_path(allowlist, source)
    output = File.expand_path(output)
    raise Error, "Output already exists; refusing to overwrite" if File.exist?(output)

    entries = File.readlines(allowlist, chomp: true).map do |line|
      value = line.strip
      next if value.empty? || value.start_with?("#")
      raise Error, "Invalid allowlist path" if value.start_with?("/") || value.include?("\\") || value.split("/").any? { |part| part.empty? || part == "." || part == ".." }
      raise Error, "Allowlist must contain exact file paths, not globs" if value.match?(/[?*\[\]]/)
      value
    end.compact
    raise Error, "Allowlist is empty or contains duplicate entries" if entries.empty? || entries.uniq.length != entries.length

    entries.each do |relative|
      path = File.join(source, relative)
      raise Error, "Missing allowlisted file: #{relative}" unless File.file?(path)
      raise Error, "Symlinks are not allowed: #{relative}" if File.symlink?(path)
      real = File.realpath(path)
      raise Error, "Allowlisted path escapes source tree: #{relative}" unless real.start_with?(source + File::SEPARATOR)
    end

    parent = File.dirname(output)
    FileUtils.mkdir_p(parent)
    stage = Dir.mktmpdir(".public-export-", parent)
    begin
      entries.each do |relative|
        from = File.join(source, relative)
        to = File.join(stage, relative)
        FileUtils.mkdir_p(File.dirname(to))
        FileUtils.copy_file(from, to, true)
        sanitize_public_file!(to) if relative.downcase.end_with?(".png")
      end
      scan_for_private_data!(stage, entries)
      manifest = {
        "format" => 1,
        "files" => entries.sort.map do |relative|
          path = File.join(stage, relative)
          {"path" => relative, "bytes" => File.size(path), "sha256" => Digest::SHA256.file(path).hexdigest}
        end
      }
      File.write(File.join(stage, "PUBLIC_EXPORT_MANIFEST.json"), JSON.pretty_generate(manifest) + "\n")

      git!(stage, "init", "-q")
      git!(stage, "checkout", "-q", "-b", "main")
      git!(stage, "add", "--all", "--force")
      git!(stage, "-c", "user.name=LectureTranslate Maintainers", "-c", "user.email=maintainers@lecturetranslate.invalid",
           "commit", "-q", "-m", "Initial sanitized public snapshot")
      paths = git!(stage, "-c", "core.quotepath=false", "ls-files").lines.map(&:chomp).sort
      expected = (entries + ["PUBLIC_EXPORT_MANIFEST.json"]).sort
      unless paths == expected
        unexpected = paths - expected
        missing = expected - paths
        detail = []
        detail << "unexpected: #{unexpected.join(', ')}" unless unexpected.empty?
        detail << "missing: #{missing.join(', ')}" unless missing.empty?
        raise Error, "Snapshot path mismatch (#{detail.join('; ')})"
      end
      raise Error, "Snapshot must have a single clean root commit" unless git!(stage, "rev-list", "--count", "HEAD").strip == "1" && git!(stage, "status", "--porcelain").empty?

      File.rename(stage, output)
      {"path" => output, "file_count" => manifest.fetch("files").length,
       "commit" => git!(output, "rev-parse", "HEAD").strip, "branch" => "main"}
    rescue Exception
      FileUtils.remove_entry(stage) if stage && File.directory?(stage)
      raise
    end
  end

  def self.scan_for_private_data!(root, entries)
    local_path = Regexp.new("/" + "(?:Users|var/folders)" + "/[^\\s/]+")
    token = Regexp.new("(?i)(?:sk-" + "[A-Za-z0-9_-]{24,}|gh[pousr]_" + "[A-Za-z0-9_]{24,}|xox[baprs]-[A-Za-z0-9-]{20,})")
    email = /\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b/i
    allowed_placeholder_domains = %w[example.com example.org example.net example.invalid localhost lecturetranslate.invalid]

    entries.each do |relative|
      path = File.join(root, relative)
      data = File.binread(path)
      text = data.dup.force_encoding(Encoding::UTF_8)
      next unless text.valid_encoding? && !text.include?("\0")
      raise Error, "Personal absolute path detected in: #{relative}" if text.match?(local_path)
      raise Error, "Credential-like token detected in: #{relative}" if text.match?(token)
      text.scan(email).each do |address|
        domain = address.split("@", 2).last.downcase
        raise Error, "Non-placeholder email address detected in: #{relative}" unless allowed_placeholder_domains.include?(domain)
      end
    end
  end

  # Public screenshots should not carry capture-time/device/location metadata.
  # Keep image/color chunks byte-for-byte and remove only metadata chunks.
  def self.sanitize_public_file!(path)
    data = File.binread(path)
    signature = "\x89PNG\r\n\x1a\n".b
    raise Error, "Invalid PNG signature: #{File.basename(path)}" unless data.start_with?(signature)

    metadata_chunks = %w[eXIf tEXt zTXt iTXt]
    output = signature.dup
    offset = signature.bytesize
    saw_end = false
    while offset < data.bytesize
      raise Error, "Truncated PNG chunk: #{File.basename(path)}" if offset + 12 > data.bytesize
      length = data.byteslice(offset, 4).unpack1("N")
      type = data.byteslice(offset + 4, 4)
      chunk_end = offset + 12 + length
      raise Error, "Truncated PNG chunk: #{File.basename(path)}" if chunk_end > data.bytesize
      chunk = data.byteslice(offset, chunk_end - offset)
      output << chunk unless metadata_chunks.include?(type)
      offset = chunk_end
      if type == "IEND"
        saw_end = true
        break
      end
    end
    raise Error, "PNG has no complete IEND chunk: #{File.basename(path)}" unless saw_end && offset == data.bytesize
    File.binwrite(path, output)
  end

  def self.git!(root, *args)
    output, status = Open3.capture2e("git", "-C", root, *args)
    raise Error, "Git snapshot operation failed: #{args.first}" unless status.success?
    output
  end
end

if $PROGRAM_NAME == __FILE__
  begin
  options = {source: Dir.pwd, allowlist: "PUBLIC_EXPORT_FILES.txt"}
  parser = OptionParser.new do |opts|
    opts.banner = "Usage: ruby Scripts/export-public.rb [--source DIR] [--allowlist FILE] [--output DIR]"
    opts.on("--source DIR", "Source working tree (default: current directory)") { |value| options[:source] = value }
    opts.on("--allowlist FILE", "Exact relative-path manifest") { |value| options[:allowlist] = value }
    opts.on("--output DIR", "New snapshot directory; it must not already exist") { |value| options[:output] = value }
  end
  parser.parse!
  abort parser.to_s unless ARGV.empty?
  unless options[:output]
    build = File.join(File.realpath(options[:source]), ".build")
    FileUtils.mkdir_p(build)
    options[:output] = Dir.mktmpdir("lecturetranslate-public-", build)
    FileUtils.remove_entry(options[:output])
  end
  result = PublicExport.run(**options)
  puts "Public snapshot ready: #{result.fetch('path')}"
  puts "Files: #{result.fetch('file_count')} · branch: #{result.fetch('branch')} · clean initial commit: #{result.fetch('commit')}"
  puts "No remote configured or contacted. Review this snapshot before any publication."
  rescue PublicExport::Error => error
    warn "Public export refused: #{error.message}"
    exit 1
  end
end
