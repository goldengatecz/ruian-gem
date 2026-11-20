require 'tmpdir'

class Ruian
  module ZipExtraction
    class LimitExceeded < StandardError; end

    # Current archives have 6,300 entries and unpack to 360 MB; the largest file
    # has 20 MB and no file compresses more than 8 times.
    LIMITS = {
      entries: 20_000,
      entry_bytes: 256 * 1024**2,
      total_bytes: 2 * 1024**3,
      compression_ratio: 100,
      seconds: 600
    }.freeze

    private

    def extract_into(staging)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + LIMITS[:seconds]
      archive_bytes = filepath.size
      # Rubyzip reads as many central directory records as the archive
      # declares, including duplicate names, before Zip::File.open returns.
      entry_count = Zip::File.count_entries(filepath.to_s)
      if entry_count > LIMITS[:entries]
        raise LimitExceeded, "RUIAN archive has #{entry_count} entries, limit #{LIMITS[:entries]}"
      end

      Zip::File.open(filepath) do |zip_file|
        entries = zip_file.entries.select { |entry| extracted?(entry) }
        check_budget!(entries, archive_bytes)
        # Declared compressed sizes may overlap or lie; the archive itself bounds
        # everything unpacked from it.
        allowance = LIMITS[:compression_ratio] * archive_bytes
        entries.each do |entry|
          allowance -= stream(entry, staging.join(entry_path(entry)), allowance, deadline)
        end
      end
      # An archive without CSV files still replaces the old ones, as before.
      staging.join(csv_subdirectory).mkpath
    end

    # Rejects the declared sizes before writing anything; stream then refuses
    # every entry that unpacks to more than it declared or the archive allows.
    def check_budget!(entries, archive_bytes)
      total = 0
      entries.each do |entry|
        total += entry.size
        if entry.size > LIMITS[:entry_bytes]
          raise LimitExceeded, "RUIAN archive entry #{entry.name} exceeds #{LIMITS[:entry_bytes]} bytes"
        end
        if total > LIMITS[:total_bytes]
          raise LimitExceeded, "RUIAN archive exceeds #{LIMITS[:total_bytes]} extracted bytes"
        end
        # A declared compressed size beyond the archive itself cannot be true.
        if entry.size > LIMITS[:compression_ratio] * entry.compressed_size.clamp(1, archive_bytes)
          raise LimitExceeded, "RUIAN archive entry #{entry.name} exceeds compression ratio #{LIMITS[:compression_ratio]}"
        end
      end
    end

    def stream(entry, target, allowance, deadline)
      target.dirname.mkpath
      written = 0
      target.open('wb') do |file|
        entry.get_input_stream do |input|
          while (chunk = input.sysread(Zip::Decompressor::CHUNK_SIZE))
            written += chunk.bytesize
            if written > entry.size
              raise LimitExceeded, "RUIAN archive entry #{entry.name} is larger than its declared size"
            end
            if written > allowance
              raise LimitExceeded, "RUIAN archive exceeds compression ratio #{LIMITS[:compression_ratio]}"
            end
            if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
              raise LimitExceeded, "RUIAN archive extraction exceeded #{LIMITS[:seconds]} seconds"
            end

            file.write(chunk)
          end
        end
      end
      written
    end

    # Only regular files inside the CSV directory are read by the importer.
    def extracted?(entry)
      path = entry_path(entry)
      entry.file? && path.to_s.start_with?("#{csv_subdirectory}/") && extract?(entry, directory.join(path))
    end

    def entry_path(entry)
      Pathname.new(entry.name).cleanpath
    end

    def csv_subdirectory
      csv_directory.relative_path_from(directory)
    end

    def staging_prefix
      ".#{file_name}-extract-"
    end
  end
end
