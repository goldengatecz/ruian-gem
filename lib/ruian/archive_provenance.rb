require 'digest'
require 'json'
require 'ruian/cuzk_http'

class Ruian
  module ArchiveProvenance
    Error = CuzkHttp::Error

    private

    def fetch(uri, file)
      cuzk_http.get(uri) { |chunk| file.write(chunk) }
    end

    def trusted_uri!(target)
      cuzk_http.trusted_uri!(target)
    end

    def cuzk_http
      @cuzk_http ||= CuzkHttp.new
    end

    def verify_archive!
      manifest = read_manifest
      raise Error, "Refusing RUIAN archive #{filepath.basename}: missing download manifest" unless manifest
      return if manifest == manifest_for(filepath, source_url: @update_url || url)

      raise Error, "Refusing RUIAN archive #{filepath.basename}: content does not match its download manifest"
    end

    def read_manifest
      JSON.parse(manifest_path.read)
    rescue Errno::ENOENT, JSON::ParserError
      nil
    end

    def write_manifest(archive = filepath, source_url: url)
      manifest_path.write(JSON.generate(manifest_for(archive, source_url: source_url)))
    end

    def manifest_for(archive, source_url:)
      { 'url' => source_url, 'size' => File.size(archive), 'sha256' => Digest::SHA256.file(archive).hexdigest }
    end

    def manifest_path
      Pathname.new("#{filepath}.manifest.json")
    end

    def partial_path
      Pathname.new("#{filepath}.part")
    end
  end
end
