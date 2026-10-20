# SPDX-License-Identifier: AGPL-3.0-or-later

module Bankimport
  module Parsers
    # Lecture d'un relevé OFX (D-BKI-002), en version 1 (SGML, balises sans
    # fermeture) comme en version 2 (XML) : opérations `STMTTRN` (date
    # `DTPOSTED`, montant `TRNAMT`, identifiant `FITID`, libellé `NAME` et
    # `MEMO`, numéro `CHECKNUM` ou `REFNUM`, bénéficiaire `NAME` ou
    # `PAYEE`, IBAN de la contrepartie `BANKACCTTO`), compte (`ACCTID`), devise
    # (`CURDEF`), solde de fin (`LEDGERBAL`). Jeu de caractères de l'en-tête
    # (`CHARSET:1252`, `encoding="…"`), sinon UTF-8 s'il est valide.
    module OfxReader
      def self.ofx?(text : String) : Bool
        head = text[0, 4096].upcase
        head.includes?("OFXHEADER") || head.includes?("<OFX>")
      end

      def self.parse(bytes : Bytes) : Parsed
        parsed = Parsed.new
        text = decode(bytes)
        unless ofx?(text)
          parsed.issue(0, "file.not_ofx")
          return parsed
        end
        parsed.account_number = clean_tag(text, "ACCTID", 64)
        parsed.currency_code = clean_tag(text, "CURDEF", 3).upcase
        if balance = section(text, "LEDGERBAL")
          parsed.end_balance = Amounts.parse(tag(balance, "BALAMT"))
          parsed.statement_on = Dates.compact(tag(balance, "DTASOF"))
        end
        transactions(text).each_with_index(1) { |block, position| read(parsed, block, position) }
        parsed.issue(0, "file.empty") if parsed.lines.empty? && parsed.issues.empty?
        parsed
      end

      private def self.decode(bytes : Bytes) : String
        head = String.new(bytes[0, Math.min(bytes.size, 512)]).scrub.upcase
        if head.includes?("CHARSET:1252") || head.matches?(/ENCODING="(WINDOWS-1252|ISO-8859-1|ISO-8859-15)"/)
          Text.cp1252(bytes)
        else
          Text.guess(bytes)
        end
      end

      # Blocs `STMTTRN`, fermés ou non (SGML).
      private def self.transactions(text : String) : Array(String)
        blocks = text.split(/<STMTTRN>/i)
        return [] of String if blocks.size < 2
        blocks[1..].map { |block| block.split(/<\/STMTTRN>|<\/BANKTRANLIST>/i).first }
      end

      private def self.read(parsed : Parsed, block : String, position : Int32) : Nil
        date_text = tag(block, "DTPOSTED")
        date = Dates.compact(date_text)
        return parsed.issue(position, "line.date", {"value" => date_text}) if date.nil?
        amount_text = tag(block, "TRNAMT")
        amount = Amounts.parse(amount_text)
        return parsed.issue(position, "line.amount", {"value" => amount_text}) if amount.nil?
        return parsed.issue(position, "line.zero") if amount.zero?
        name = clean_tag(block, "NAME", 255)
        memo = clean_tag(block, "MEMO", 2000)
        label = name.empty? ? memo[0, 255] : name
        return parsed.issue(position, "line.label") if label.empty?
        reference = clean_tag(block, "CHECKNUM", 64).presence || clean_tag(block, "REFNUM", 64)
        parsed.lines << ParsedLine.new(position, date, amount, label, extra: memo == label ? "" : memo,
          reference: reference, fitid: clean_tag(block, "FITID", 255), counterparty: clean_tag(block, "PAYEEID", 255),
          payee: name, iban: counterparty_iban(block))
      end

      # IBAN du compte de la contrepartie (`BANKACCTTO`, virement), s'il en a
      # la forme ; un numéro de compte national est ignoré.
      private def self.counterparty_iban(block : String) : String
        to = section(block, "BANKACCTTO") || return ""
        to = to.split(/<\/BANKACCTTO>/i).first
        Parsers.iban(tag(to, "ACCTID"))
      end

      private def self.section(text : String, name : String) : String?
        text.split(/<#{name}>/i)[1]?
      end

      # Valeur d'une balise : jusqu'à la balise suivante ou la fin de ligne.
      private def self.tag(text : String, name : String) : String
        text.match(/<#{name}>\s*([^<\r\n]*)/i).try(&.[1].strip) || ""
      end

      private def self.clean_tag(text : String, name : String, max : Int32) : String
        Parsers.clean(Parsers.unescape(tag(text, name)), max)
      end
    end
  end
end
