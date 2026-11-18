# Build input can be the Windows 1.21.0 ZIP or a checkout with the curated
# artwork. Missing checkout files are fetched by commit only, then verified.
require "digest"
require "fileutils"
require "open3"
require "uri"

resources, source, input = ARGV
art_commit = "9d6257fc714fe8e430eb782769f321cf81c2dff3"
runtime_commit = "db5d182f7740e0e80b8a2d16c4334f668796449d"
zip = input && File.file?(input)
if zip && Digest::SHA256.file(input).hexdigest != "2c8b96b10bce341e1e939f03278fb8818c482896b154855ddfd046fd5714edef"
  abort "The supplied ZIP does not match the Windows 1.21.0 release."
end
rows = File.readlines(File.join(__dir__, "Artwork.tsv"), chomp: true).map { |line| line.split("\t") }
abort "Incomplete BetterIcon artwork inventory" unless rows.size == 250
rows.each do |sha, packaged, path|
  brand = packaged.start_with?("Windows/Assets/AppIcons/")
  relative = brand ? "Brand/" + packaged.delete_prefix("Windows/Assets/AppIcons/") : "Packs/" + packaged
  destination = File.join(resources, relative)
  FileUtils.mkdir_p(File.dirname(destination))
  if zip
    bytes, ok = Open3.capture2("/usr/bin/unzip", "-p", input, packaged)
    abort "Missing artwork in ZIP: #{packaged}" unless ok.success?
  else
    candidates = [File.join(input || source, path), File.join(input || source, packaged), File.join(source, path)]
    local = candidates.find { |file| File.file?(file) && File.size?(file) && Digest::SHA256.file(file).hexdigest == sha }
    if local
      bytes = File.binread(local)
    else
      ref = brand ? runtime_commit : art_commit
      url = "https://raw.githubusercontent.com/BinziiBinzet/bettericon-craft-apps/#{ref}/" + URI::DEFAULT_PARSER.escape(path)
      bytes, ok = Open3.capture2("/usr/bin/curl", "-fsSL", "--retry", "2", url)
      abort "Could not load #{path}. Supply the Windows release ZIP to build offline." unless ok.success?
    end
  end
  abort "Incorrect artwork for #{packaged}" unless Digest::SHA256.hexdigest(bytes.b) == sha
  File.binwrite(destination, bytes)
end
puts "Verified 218 pack images and 32 BetterIcon images against Windows 1.21.0."
