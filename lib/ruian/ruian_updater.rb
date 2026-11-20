require 'date'
require 'pathname'
require 'fileutils'
require 'zip'
require 'ruian/archive_provenance'
require 'ruian/zip_extraction'

class Ruian
  class RuianUpdater
    include ArchiveProvenance
    include ZipExtraction

    attr_reader :directory

    def initialize(directory = fixtures_directory)
      @directory = directory
    end

    def update!(remove: true, download_new: false)
      download if !filepath.exist? || download_new
      unpack
      remove_temp if remove
    rescue StandardError
      discard_archive
      raise
    end

    def download
      uri = trusted_uri!(url)
      puts "Downloading #{uri} to #{filepath}"
      discard_archive
      File.open(partial_path, 'wb') { |file| fetch(uri, file) }
      # A manifest without its archive only causes a fresh download next time.
      write_manifest(partial_path)
      File.rename(partial_path, filepath)
    rescue StandardError
      discard_archive
      raise
    end

    def unpack
      verify_archive!
      print 'Extracting...'
      recover_staging
      staging = Pathname.new(Dir.mktmpdir(staging_prefix, directory))
      extract_into(staging)
      publish_csv(staging)
      puts 'done'
    ensure
      # Preserve the backup if restoring it also failed.
      FileUtils.rm_rf(staging) if staging && (csv_directory.exist? || !staging.join('previous').exist?)
    end

    def most_recent_file(at = Time.respond_to?(:current) ? Time.current : Time.now)
      (Date.new(at.year, at.month, 1) - 1).strftime('%Y%m%d')
    end

    def url
      raise 'Not implemented'
    end

    def file_name
      raise 'Not implemented'
    end

    def remove_temp
      puts "Removing downloaded file #{filepath}"
      discard_archive
    end

    def remove_old
      puts "Removing: #{csv_directory}"
      FileUtils.rm_rf(csv_directory)
    end

    def fixtures_directory
      Ruian.root.join('fixtures')
    end

    def csv_directory
      directory.join('CSV')
    end

    def filepath
      directory.join(file_name)
    end

    def extract?(entry, full_path)
      true
    end

    private

    def discard_archive
      FileUtils.rm_f([filepath, manifest_path, partial_path])
    end

    def recover_staging
      directory.glob("#{staging_prefix}*").each do |staging|
        previous = staging.join('previous')
        File.rename(previous, csv_directory) if previous.exist? && !csv_directory.exist?
        FileUtils.rm_rf(staging)
      end
    end

    def publish_csv(staging)
      previous = staging.join('previous')
      File.rename(csv_directory, previous) if csv_directory.exist?
      File.rename(staging.join(csv_subdirectory), csv_directory)
    rescue StandardError
      File.rename(previous, csv_directory) if previous.exist? && !csv_directory.exist?
      raise
    end
  end
end
