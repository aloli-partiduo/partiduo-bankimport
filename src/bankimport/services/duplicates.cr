# SPDX-License-Identifier: AGPL-3.0-or-later

module Bankimport
  # Doublons (D-BKI-005) : une ligne déjà importée dans le même journal
  # n'est pas proposée deux fois.
  #
  # * Avec un FITID (OFX) : même FITID dans le journal, ou plus haut dans le
  #   fichier.
  # * Sinon, ou contre une ligne importée sans FITID : même empreinte (date,
  #   montant, libellé normalisé), en comptant les occurrences — deux
  #   paiements identiques le même jour restent deux lignes si le journal
  #   n'en connaît qu'un.
  #
  # Les écritures déjà passées à la main dans le journal, de même date et de
  # même montant, sont *signalées* (`recorded_entry_id`), pas écartées.
  # Interne.
  module Duplicates
    # Empreinte d'une ligne (64 caractères hexadécimaux).
    def self.fingerprint(date : Time, amount : BigDecimal, label : String) : String
      text = "#{date.to_s("%Y-%m-%d")}|#{amount}|#{Categorizer.normalize(label)}"
      Digest::SHA256.hexdigest(text)
    end

    # Ligne existante dont chaque ligne lue serait le doublon (`nil` :
    # nouvelle), dans l'ordre des lignes.
    def self.detect(ledger_id : Int64, lines : Array(Parsers::ParsedLine)) : Array(Int64?)
      prints = lines.map { |line| fingerprint(line.date, line.amount, line.label) }
      fitids = lines.map(&.fitid).reject(&.empty?)
      existing = prints.empty? ? [] of Line : Line.filter(ledger_id: ledger_id, fingerprint__in: prints.uniq).exclude(status: "duplicate").order(:id).to_a
      by_fitid = fitids.empty? ? {} of String => Int64 : Line.filter(ledger_id: ledger_id, fitid__in: fitids.uniq).exclude(status: "duplicate")
        .to_a.to_h { |row| {row.fitid.to_s, row.id!.to_i64} }
      # Lignes existantes par empreinte : toutes, et celles sans FITID.
      all_rows = existing.group_by(&.fingerprint.to_s)
      plain_rows = existing.select(&.fitid.to_s.empty?).group_by(&.fingerprint.to_s)
      seen_fitids = Set(String).new
      used = Hash(String, Int32).new(0)
      used_plain = Hash(String, Int32).new(0)

      lines.map_with_index do |line, index|
        print = prints[index]
        if !line.fitid.empty?
          next by_fitid[line.fitid] if by_fitid.has_key?(line.fitid)
          if seen_fitids.includes?(line.fitid)
            next 0_i64
          end
          seen_fitids << line.fitid
          rows = plain_rows[print]? || [] of Line
          rank = used_plain[print]
          used_plain[print] = rank + 1
          rows[rank]?.try(&.id!.to_i64)
        else
          rows = all_rows[print]? || [] of Line
          rank = used[print]
          used[print] = rank + 1
          rows[rank]?.try(&.id!.to_i64)
        end
      end
    end

    # Écriture du journal de même date et de même montant, passée hors de
    # l'extension, pour chaque ligne à traiter (si l'acteur lit les
    # écritures).
    def self.flag_recorded(actor : Partiduo::Api::Actor, rows : Array(Line)) : Nil
      rows.each do |row|
        next unless row.status == "pending"
        amount = row.amount!.abs
        query = Partiduo::Api::Accounting::EntryQuery.new(ledger_id: row.ledger_id!.to_i64, date_from: row.date!,
          date_to: row.date!, amount_min: amount, amount_max: amount, include_cancelled: false, limit: 5)
        entry = Partiduo::Api::Accounting.entries(actor, query).find { |item| !item.source.starts_with?(Transfer::SOURCE) }
        next if entry.nil?
        row.recorded_entry_id = entry.id
        row.save!
      end
    rescue Partiduo::Api::AccessDenied
      nil
    end
  end
end
