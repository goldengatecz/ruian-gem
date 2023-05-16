require 'csv'

class Ruian
  class Parser < CSV
    CSV_OPTIONS = { :encoding => 'windows-1250', :col_sep => ';', :quote_char => '"', :headers => true }

    def self.foreach(path, mode = 'r', **options, &block)
      options = Ruian::Parser::CSV_OPTIONS.merge(options)
      super(path, mode, **options, &block)
    end
  end
end
