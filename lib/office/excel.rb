require 'office/package'
require 'office/constants'
require 'office/errors'
require 'office/logger'

module Office
  class ExcelWorkbook < Package
    attr_accessor :workbook_part
    attr_accessor :shared_strings
    attr_accessor :sheets
    
    def initialize(filename)
      super(filename)

      @workbook_part = get_relationship_target(EXCEL_WORKBOOK_TYPE)
      raise PackageError.new("Excel workbook package '#{@filename}' has no workbook part") if @workbook_part.nil?

      parse_shared_strings
      parse_workbook_xml
    end

    def self.blank_workbook
      ExcelWorkbook.new(File.join(File.dirname(__FILE__), 'content', 'blank.xlsx'))
    end

    def parse_shared_strings
      shared_strings_part = @workbook_part.get_relationship_target(EXCEL_SHARED_STRINGS_TYPE)
      @shared_strings = SharedStringTable.new(shared_strings_part) unless shared_strings_part.nil?
    end
    
    def parse_workbook_xml
      @sheets_node = @workbook_part.xml.at_xpath("/xmlns:workbook/xmlns:sheets")
      raise PackageError.new("Excel workbook '#{@filename}' is missing sheets container") if @sheets_node.nil?

      @sheets = []
      @sheets_node.xpath("xmlns:sheet").each { |s| @sheets << Sheet.new(s, self) }
    end

    def debug_dump
      super
      @shared_strings.debug_dump unless @shared_strings.nil?

      rows = @sheets.collect { |s| ["#{s.name}", "#{s.id}", "#{s.worksheet_part.name}"] }
      Logger.debug_dump_table("Excel Workbook Sheets", ["Name", "Sheet ID", "Part"], rows)
      
      @sheets.each { |s| s.sheet_data.debug_dump }
    end
  end
  
  class Sheet
    attr_accessor :workbook_node
    attr_accessor :name
    attr_accessor :id
    attr_accessor :worksheet_part
    attr_accessor :sheet_data

    def initialize(sheet_node, workbook)
      @workbook_node = sheet_node
      @name = sheet_node["name"]
      @id = sheet_node["sheetId"]
      @worksheet_part = workbook.workbook_part.get_relationship_by_id(sheet_node["id"]).target_part
      
      data_node = worksheet_part.xml.at_xpath("/xmlns:worksheet/xmlns:sheetData")
      raise PackageError.new("Excel worksheet '#{@name} in workbook '#{workbook.filename}' has no sheet data") if data_node.nil?
      @sheet_data = SheetData.new(data_node, self, workbook)
    end

    def to_csv(separator = ',')
      @sheet_data.to_csv(separator)
    end
  end
  
  class SheetData
    attr_accessor :node
    attr_accessor :sheet
    attr_accessor :workbook
    attr_accessor :rows

    def initialize(node, sheet, workbook)
      @node = node
      @sheet = sheet
      @workbook = workbook

      @rows = []
      node.xpath("xmlns:row").each { |r| @rows << Row.new(r, workbook.shared_strings) }
    end

    def to_csv(separator)
      data = []
      column_count = 0
      @rows.each do |r|
        data.push([]) until data.length > r.number
        data[r.number] = r.to_ary
        column_count = [column_count, data[r.number].length].max
      end
      data.each { |d| d.push("") until d.length == column_count }

      csv = ""
      data.each do |d|
        items = d.map { |i| i.index(separator).nil? ? i : "'#{i}'" }
        csv << items.join(separator) << "\n"
      end
      csv
    end

    def debug_dump
      data = []
      column_count = 1
      @rows.each do |r|
        data.push([]) until data.length > r.number
        data[r.number] = r.to_ary.insert(0, (r.number + 1).to_s)
        column_count = [column_count, data[r.number].length].max
      end
      
      headers = [ "" ]
      0.upto(column_count - 2) { |i| headers << Cell.column_name(i) }
      
      Logger.debug_dump_table("Excel Sheet #{@sheet.worksheet_part.name}", headers, data)
    end
  end

  class Row
    attr_accessor :node
    attr_accessor :number
    attr_accessor :spans
    attr_accessor :cells
    
    def initialize(row_node, string_table)
      @node = row_node
      
      @number = row_node["r"].to_i - 1
      @spans = row_node["spans"]
      
      @cells = []
      node.xpath("xmlns:c").each { |c| @cells << Cell.new(c, string_table) }
    end
    
    def to_ary
      ary = []
      @cells.each do |c|
        ary.push("") until ary.length > c.column_num
        ary[c.column_num] = c.value
      end
      ary 
    end
  end

  class Cell
    attr_accessor :node
    attr_accessor :location
    attr_accessor :style
    attr_accessor :data_type
    attr_accessor :value_node
    attr_accessor :shared_string
 
    def initialize(c_node, string_table)
      @node = c_node
      @location = c_node["r"]
      @style = c_node["s"]
      @data_type = c_node["t"]
      @value_node = c_node.at_xpath("xmlns:v")
      
      if is_string? && !@value_node.nil?
        string_id = @value_node.content.to_i
        @shared_string = string_table.get_string_by_id(string_id)
        raise PackageError.new("Excel cell #{@location} refers to invalid shared string #{string_id}") if @shared_string.nil?
        @shared_string.add_cell(self)
      end
    end
    
    def is_string?
      data_type == "s"
    end

    def self.column_name(index)
      name = ""
      while index >= 0
        name << ('A'.ord + (index % 26)).chr
        index = index/26 - 1
      end
      name.reverse
    end

    def column_num
      letters = /([a-z]+)\d+/i.match(@location)[1].downcase.reverse

      num = letters[0].ord - 'a'.ord
      1.upto(letters.length - 1) { |i| num += (letters[i].ord - 'a'.ord + 1) * (26 ** i) }
      num
    end
    
    def row_num
      /[a-z]+(\d+)/i.match(@location)[1].to_i - 1
    end
    
    def value
      return nil if @value_node.nil?
      is_string? ? @shared_string.text : @value_node.content
    end
  end
  
  class SharedStringTable
    attr_accessor :node
    
    def initialize(part)
      @node = part.xml.at_xpath("/xmlns:sst")
      @count_attr = @node.attribute("count")
      @unique_count_attr = @node.attribute("uniqueCount")

      @strings_by_id = {}
      @strings_by_text = {}
      node.xpath("xmlns:si").each do |si|
        string = SharedString.new(si, @strings_by_id.length)
        @strings_by_id[string.id] = string
        @strings_by_text[string.text] = string
      end
    end

    def get_string_by_id(id)
      @strings_by_id[id]
    end

    def debug_dump
      rows = @strings_by_id.values.collect do |s|
        cells = s.cells.collect { |c| c.location }
        ["#{s.id}", "#{s.text}", "#{cells.join(', ')}"]
      end
      footer = "count = #{@count_attr.value}, unique count = #{@unique_count_attr.value}"
      Logger.debug_dump_table("Excel Workbook Shared Strings", ["ID", "Text", "Cells"], rows, footer)
    end
  end
  
  class SharedString
    attr_accessor :node
    attr_accessor :text_node
    attr_accessor :id
    attr_accessor :cells

    def initialize(si_node, id)
      @node = si_node
      @id = id
      @text_node = si_node.at_xpath("xmlns:t")
      @cells = []
    end
    
    def text
      text_node.content
    end
    
    def add_cell(cell)
      @cells << cell
    end
  end
end