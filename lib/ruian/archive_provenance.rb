require 'digest'
require 'json'
require 'net/http'

class Ruian
  module ArchiveProvenance
    class Error < StandardError; end

    # ČÚZK redirects IPv4 clients from its .cz domain to its .gov.cz domain.
    TRUSTED_HOSTS = %w[vdp.cuzk.cz vdp.cuzk.gov.cz].freeze
    MAX_REDIRECTS = 3
    HTTP_OPTIONS = {
      use_ssl: true,
      verify_mode: OpenSSL::SSL::VERIFY_PEER,
      verify_hostname: true,
      open_timeout: 30,
      read_timeout: 120,
      # A retry must start with an empty staging file.
      max_retries: 0
    }.freeze

    private

    def fetch(uri, file)
      (MAX_REDIRECTS + 1).times do
        location = nil
        Net::HTTP.start(uri.host, uri.port, HTTP_OPTIONS) do |http|
          http.request(Net::HTTP::Get.new(uri)) do |response|
            case response
            when Net::HTTPOK then response.read_body { |chunk| file.write(chunk) }
            when Net::HTTPRedirection then location = response['location'].to_s
            else raise Error, "RUIAN archive download failed with HTTP #{response.code}: #{uri}"
            end
          end
        end
        return unless location

        uri = trusted_uri!(uri.merge(location))
      end
      raise Error, "Too many redirects while downloading RUIAN archive #{url}"
    end

    def trusted_uri!(target)
      uri = URI(target.to_s)
      return uri if uri.is_a?(URI::HTTPS) && TRUSTED_HOSTS.include?(uri.host&.downcase) && uri.port == 443

      raise Error, "Refusing RUIAN archive outside the approved ČÚZK HTTPS origins: #{uri}"
    end

    def verify_archive!
      manifest = read_manifest
      raise Error, "Refusing RUIAN archive #{filepath.basename}: missing download manifest" unless manifest
      return if manifest == manifest_for(filepath)

      raise Error, "Refusing RUIAN archive #{filepath.basename}: content does not match its download manifest"
    end

    def read_manifest
      JSON.parse(manifest_path.read)
    rescue Errno::ENOENT, JSON::ParserError
      nil
    end

    def write_manifest(archive = filepath)
      manifest_path.write(JSON.generate(manifest_for(archive)))
    end

    def manifest_for(archive)
      { 'url' => url, 'size' => File.size(archive), 'sha256' => Digest::SHA256.file(archive).hexdigest }
    end

    def manifest_path
      Pathname.new("#{filepath}.manifest.json")
    end

    def partial_path
      Pathname.new("#{filepath}.part")
    end
  end
end
