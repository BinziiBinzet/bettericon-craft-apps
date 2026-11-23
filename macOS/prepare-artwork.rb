# Build input may be the Windows 1.21.0 ZIP and/or a checkout with current artwork.
# Every file is checked against the current manifest before it is packaged.
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
abort "Incomplete BetterIcon artwork inventory" unless rows.size == 305
rows.each do |sha, packaged, path|
  brand = packaged.start_with?("Windows/Assets/AppIcons/")
  relative = brand ? "Brand/" + packaged.delete_prefix("Windows/Assets/AppIcons/") : "Packs/" + packaged
  destination = File.join(resources, relative)
  FileUtils.mkdir_p(File.dirname(destination))
  bytes = nil
  if zip
    candidate, ok = Open3.capture2("/usr/bin/unzip", "-p", input, packaged, err: File::NULL)
    bytes = candidate if ok.success? && Digest::SHA256.hexdigest(candidate.b) == sha
  end
  unless bytes
    input_dir = input && File.directory?(input) ? input : source
    candidates = [File.join(input_dir, path), File.join(input_dir, packaged), File.join(source, path)]
    local = candidates.find { |file| File.file?(file) && File.size?(file) && Digest::SHA256.file(file).hexdigest == sha }
    bytes = File.binread(local) if local
  end
  unless bytes
    ref = brand ? runtime_commit : art_commit
    url = "https://raw.githubusercontent.com/BinziiBinzet/bettericon-craft-apps/#{ref}/" + URI::DEFAULT_PARSER.escape(path)
    candidate, ok = Open3.capture2("/usr/bin/curl", "-fsSL", "--retry", "2", url)
    bytes = candidate if ok.success?
  end
  abort "Missing or incorrect artwork for #{packaged}; supply the current artwork checkout." unless bytes && Digest::SHA256.hexdigest(bytes.b) == sha
  File.binwrite(destination, bytes)
end
puts "Verified 265 pack images and 40 BetterIcon images."
