class Ruian
  class FilesUpdater < RuianUpdater
    def csv_directory
      directory.join('CSV')
    end

    def file_name
      'csv.zip'
    end

    def url
      "https://vdp.cuzk.cz/vymenny_format/csv/#{snapshot_stamp}_OB_ADR_csv.zip"
    end

    def filepath
      directory.join('csv.zip')
    end
  end
end
