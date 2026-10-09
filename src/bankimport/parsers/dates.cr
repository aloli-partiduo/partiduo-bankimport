# SPDX-License-Identifier: AGPL-3.0-or-later

module Bankimport
  module Parsers
    # Lecture des dates selon le format choisi (D-BKI-002). L'ordre du jour,
    # du mois et de l'année vient du format ; le séparateur importe peu
    # (`/`, `.`, `-`, espace, et l'apostrophe des QIF : `15/01'26`). Une
    # année sur deux chiffres est de ce siècle avant 70, du précédent
    # sinon.
    module Dates
      # Code du format et ordre des parties (`d`, `m`, `y`) ; `compact` :
      # chiffres accolés (`AAAAMMJJ`).
      FORMATS = {
        "dd/mm/yyyy" => "dmy",
        "dd.mm.yyyy" => "dmy",
        "dd-mm-yyyy" => "dmy",
        "dd/mm/yy"   => "dmy",
        "dd.mm.yy"   => "dmy",
        "dd-mm-yy"   => "dmy",
        "yyyy-mm-dd" => "ymd",
        "yyyymmdd"   => "compact",
        "mm/dd/yyyy" => "mdy",
        "mm/dd/yy"   => "mdy",
      }

      def self.parse(text : String, format : String) : Time?
        value = text.strip
        return if value.empty?
        order = FORMATS[format]? || return
        return compact(value) if order == "compact" || (order == "ymd" && value.matches?(/\A\d{8}/))
        parts = value.scan(/\d+/).map(&.[0])
        return unless parts.size >= 3
        day, month, year = case order
                           when "dmy" then {parts[0], parts[1], parts[2]}
                           when "mdy" then {parts[1], parts[0], parts[2]}
                           else            {parts[2], parts[1], parts[0]}
                           end
        build(year, month, day)
      end

      # `AAAAMMJJ`, suivi ou non d'une heure (OFX : `20260115120000[0:GMT]`).
      def self.compact(text : String) : Time?
        digits = text.strip[0, 8]
        return unless digits.matches?(/\A\d{8}\z/)
        build(digits[0, 4], digits[4, 2], digits[6, 2])
      end

      private def self.build(year_text : String, month_text : String, day_text : String) : Time?
        year = year_text.to_i
        year += year < 70 ? 2000 : 1900 if year_text.size <= 2
        return unless (1900..2999).includes?(year)
        Time.utc(year, month_text.to_i, day_text.to_i)
      rescue ArgumentError
        nil
      end
    end
  end
end
