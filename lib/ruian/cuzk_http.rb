require 'net/http'

class Ruian
  class CuzkHttp
    class Error < StandardError; end

    VDP_HOSTS = %w[vdp.cuzk.cz vdp.cuzk.gov.cz].freeze
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

    def initialize(hosts = VDP_HOSTS)
      @hosts = hosts
    end

    def trusted_uri!(target)
      uri = URI(target.to_s)
      return uri if uri.is_a?(URI::HTTPS) && @hosts.include?(uri.host&.downcase) &&
        uri.port == 443 && !uri.userinfo

      raise Error, "Refusing RUIAN archive outside the approved ČÚZK HTTPS origins: #{uri}"
    end

    def get(target, missing_ok: false, max_bytes: 128 * 1024**2)
      uri = trusted_uri!(target)
      (MAX_REDIRECTS + 1).times do
        location = nil
        found = true
        Net::HTTP.start(uri.host, uri.port, HTTP_OPTIONS) do |http|
          http.request(Net::HTTP::Get.new(uri)) do |response|
            case response
            when Net::HTTPOK
              bytes = 0
              response.read_body do |chunk|
                bytes += chunk.bytesize
                raise Error, "ČÚZK response exceeds #{max_bytes} bytes: #{uri}" if bytes > max_bytes

                yield chunk
              end
            when Net::HTTPNotFound
              raise Error, "RUIAN archive download failed with HTTP 404: #{uri}" unless missing_ok

              found = false
            when Net::HTTPRedirection
              location = response['location']
              raise Error, "ČÚZK returned a redirect without a location: #{uri}" if location.to_s.empty?
            else
              raise Error, "RUIAN archive download failed with HTTP #{response.code}: #{uri}"
            end
          end
        end
        return found unless location

        uri = trusted_uri!(uri.merge(location))
      end
      raise Error, "Too many redirects while downloading RUIAN archive #{target}"
    end
  end
end
